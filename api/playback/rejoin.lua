-- The crash-rejoin flow every gamemode mod shares. A player whose game crashed comes back
-- with a seat the server kept and a log of their own run. The order is:
--
--   1. Join the lobby (detached, see L.nakama_rejoin_detached). The seat is safe and the grace
--      stops. A refused seat (a forfeit, a closed lobby) is known here, before anything is rebuilt.
--   2. Skip to the last checkpoint (the start of the second-to-last ante) with a fast-forward.
--   3. Play the remaining events at normal pace.
--   4. Resume the run: attach the lobby, then reopen the player's log block.
--
-- While 2 and 3 run, the client tells the server it is "catching up" (lobby:set_catching_up),
-- so the others see a badge. Nothing waits for it. The server's catch-up limit, if the mod set
-- one, is the only thing that ends a catch-up early.
--
-- A mod registers hooks with MPAPI.playback.register_rejoin_hooks; MPAPI.playback.rejoin picks
-- them up. A mod without hooks keeps its own function (MPAPI.playback.register_rejoin).
--
-- hooks:
--   playback_mod_id            -- the handler namespace of the mod's register_handler calls
--   read_lobby_info(args, bootstrap)  -- copies what the mod needs from the first lobby_info
--   read_run_info(args, bootstrap)    -- the same for the first run_info
--   start_run(bootstrap, on_ready)    -- boots a local run from `bootstrap`; on_ready() once it can
--                                        be played (blind select). Refuses to run while a real
--                                        lobby is current, which is why the join is detached.
--   checkpoint_options()       -- (optional) { boundary_opcodes, pause_gate }: the opcodes that
--                                 end a run attempt (MPAPI.playback.timeline_ante_starts) and the
--                                 fast-forward's pause gate
--   before_play(session)       -- (optional) called once the local run is up, before the seek
--   attach(lobby, ctx)         -- the caught-up run is about to go live. Wire the mod's lobby
--                                 events and mirrors onto `lobby` (not current yet) and restore
--                                 the mod's state (clocks, lives). ctx = { events, session,
--                                 playback_lobby }. The playback lobby's gamemode instance is
--                                 already moved onto `lobby`.
--   resumed(lobby, ctx)        -- (optional) after the log block was reopened and the server told
--                                 "caught up".
--   aborted(session)           -- (optional) the lobby was lost before the run went live.
MPAPI.playback = MPAPI.playback or {}
MPAPI.playback._rejoin_hooks = MPAPI.playback._rejoin_hooks or {}

function MPAPI.playback.register_rejoin_hooks(mod_id, hooks)
	MPAPI.playback._rejoin_hooks[mod_id] = hooks
end

-- Builds the bootstrap a local run needs and the timeline of the player's own stream from the
-- active run's events: the first match_manifest, lobby_info and run_info. Returns bootstrap,
-- timeline, or nil and a reason.
function MPAPI.playback.read_rejoin_log(events, my_id, hooks)
	local bootstrap, found, timeline = {}, {}, {}
	for _, ev in ipairs(events or {}) do
		if not found.match_manifest and ev.opcode == MPAPI.OPCODE.MATCH_MANIFEST then
			found.match_manifest = true
			bootstrap.schema_version = ev.args.schema_version
		elseif not found.lobby_info and ev.opcode == MPAPI.OPCODE.LOBBY_INFO then
			found.lobby_info = true
			bootstrap.gamemode = ev.args.gamemode
			bootstrap.ruleset = ev.args.ruleset
			hooks.read_lobby_info(ev.args, bootstrap)
		elseif not found.run_info and ev.opcode == MPAPI.OPCODE.RUN_INFO then
			found.run_info = true
			bootstrap.seed = ev.args.seed
			bootstrap.stake = ev.args.stake
			hooks.read_run_info(ev.args, bootstrap)
		end
		timeline[#timeline + 1] = { t = ev.t, player_id = my_id, opcode = ev.opcode, args = ev.args }
	end
	if not (found.lobby_info and found.run_info) then
		return nil, 'no bootstrap data in the active run'
	end
	if not MPAPI.replay.is_schema_compatible(bootstrap.schema_version) then
		return nil,
			'recording schema_version ' .. tostring(bootstrap.schema_version)
				.. ' is newer than this client understands (' .. tostring(MPAPI.replay.SCHEMA_VERSION) .. ')'
	end
	return bootstrap, timeline
end

-- Restarts `session`'s run from its own bootstrap and fast-forwards a fresh driver to
-- `target_event_index`, then calls on_ready(driver). The one restart-and-seek every caller shares
-- (a rejoin, a replay's checkpoint seek, a perspective switch).
-- opts: mod_id (handler namespace), start_run(bootstrap, on_ready), pause_gate(),
-- on_run_started() (optional; right after the local run is up, before the driver exists).
function MPAPI.playback.restart_session_and_seek(session, target_event_index, on_ready, opts)
	if session.driver then
		-- The old driver would keep ticking against a rebuilt game state it no longer matches.
		session.driver:stop()
	end
	opts.start_run(session.bootstrap, function()
		if opts.on_run_started then
			opts.on_run_started()
		end
		local driver = MPAPI.playback.new_driver(session.timeline, {
			mod_id = opts.mod_id,
			pov_player_id = session.my_id,
			schema_version = session.bootstrap.schema_version,
			-- A replay from the browser plays at the recorded pace with a speed control; a
			-- rejoin leaves this unset and keeps one entry per frame.
			paced = session.paced,
			on_complete = session.on_session_complete,
		})
		driver:finish()
		driver:fast_forward_to(target_event_index, {
			pause_gate = opts.pause_gate,
			on_done = function()
				on_ready(driver)
			end,
		})
	end)
end

-- The event index to skip to: the start of the second-to-last known ante, so the tail left for
-- normal pace is at least one full ante and starts at a clean blind-select or shop boundary. A run
-- with fewer than two ante boundaries has nothing worth skipping: play it all.
-- `starts` is a list of ante-start event indexes (MPAPI.playback.timeline_ante_starts).
function MPAPI.playback.rejoin_cutoff(starts)
	local n = #starts
	return n >= 2 and starts[n - 1] or 1
end

-- Reopens the player's own log block once the last replayed action's animations have drained (an
-- event they still emit is already in the stream), then reports "caught up". Non-blocking, so it
-- never holds up the queue it waits on.
local function resume_when_idle(lobby, session, events, my_id, on_resumed)
	G.E_MANAGER:add_event(Event({
		blocking = false,
		blockable = false,
		no_delete = true,
		func = function()
			if lobby._destroyed then
				return true
			end
			if not MPAPI.playback._queues_empty() then
				return false
			end
			local driver = session.driver
			local resolver = driver and driver._card_resolvers and driver._card_resolvers[my_id]
			MPAPI.replay.resume_run(events, resolver and resolver.by_id)
			lobby:set_catching_up(false)
			on_resumed()
			return true
		end,
	}))
end

-- Runs the whole flow. `active` is MPAPI.replay.get_active_run's answer ({ runId, lobbyCode,
-- modId, events }), `lobby_data` the seat the server kept ({ matchId, code, modId, type }).
function MPAPI.playback.run_rejoin(active, lobby_data, hooks)
	local my_id = MPAPI.get_replay_player_id()
	if not my_id then
		-- A connection can exist with its player id still unset (a Steam handshake that has not
		-- finished). Every timeline entry would get player_id = nil, and the driver's per-player
		-- tables key on it: a hard crash on the first dispatch.
		MPAPI.sendWarnMessage('[rejoin] no connection player_id available; refusing to rejoin')
		return
	end
	local bootstrap, timeline = MPAPI.playback.read_rejoin_log(active.events, my_id, hooks)
	if not bootstrap then
		MPAPI.sendWarnMessage('[rejoin] ' .. tostring(timeline) .. ' (run ' .. tostring(active.runId) .. '); refusing to rejoin')
		return
	end

	local session
	local lobby
	local aborted, live = false, false

	local function abort()
		-- A lobby left after the run went live is not a failed catch-up.
		if aborted or live then
			return
		end
		aborted = true
		if session and session.driver then
			session.driver:stop()
		end
		if hooks.aborted then
			hooks.aborted(session)
		end
	end

	local function go_live()
		if aborted or lobby._destroyed then
			abort()
			return
		end
		live = true
		-- The catch-up booted its run through the mod's own run start, which opened a fresh log
		-- block (t from 0, card ids from 1). Close it without an END or CHK: once the live lobby
		-- is current that block would record with the wrong clock and ids, and its closing hash
		-- over the post-rejoin events only reads to the server (which holds the pre-crash
		-- events too) as tampering.
		MPAPI.replay._run_active = false
		local playback_lobby = MPAPI.get_current_lobby()
		-- The catch-up's gamemode instance (run count, run decks, win latch) is the only one
		-- that knows this run: a lobby joined from outside has none.
		local instance = playback_lobby and playback_lobby:get_gamemode_instance()
		if instance then
			lobby:set_gamemode_instance(instance)
		end
		-- The run being reconnected to is the one just rebuilt: do not exit it when the lobby
		-- connects (api/mod_registry/focus.lua).
		lobby._skip_run_exit_on_connect = true
		local ctx = { events = active.events, session = session, playback_lobby = playback_lobby }
		hooks.attach(lobby, ctx)
		MPAPI._internal.lobby.attach_detached(lobby)
		resume_when_idle(lobby, session, active.events, my_id, function()
			if hooks.resumed then
				hooks.resumed(lobby, ctx)
			end
		end)
	end

	session = {
		bootstrap = bootstrap,
		timeline = timeline,
		my_id = my_id,
		on_session_complete = go_live,
	}

	local restart_opts = {
		mod_id = hooks.playback_mod_id,
		start_run = hooks.start_run,
		pause_gate = hooks.checkpoint_options and hooks.checkpoint_options().pause_gate or nil,
	}

	-- One fast-forward to the cutoff, read from the timeline. A checkpoint-index pass first would
	-- play the whole run once more before the seek: about 40 percent of a run-2 catch-up.
	restart_opts.on_run_started = function()
		if hooks.before_play then
			hooks.before_play(session)
		end
	end

	local function catch_up()
		-- A relaunched game can still show its splash (about 11 s, confirmed live 2026-10-26): the
		-- run start waits behind it. A mouse click on Reconnect skips it already (vanilla
		-- Controller:queue_L_cursor_press); a key or controller press does not. Skip it the
		-- same way.
		if G.STATE == G.STATES.SPLASH then
			G:delete_run()
			G:main_menu()
		end
		local options = hooks.checkpoint_options and hooks.checkpoint_options() or {}
		local starts = MPAPI.playback.timeline_ante_starts(timeline, options.boundary_opcodes)
		MPAPI.playback.restart_session_and_seek(session, MPAPI.playback.rejoin_cutoff(starts), function(driver)
			session.driver = driver
			if aborted then
				driver:stop()
				return
			end
			driver:play()
		end, restart_opts)
	end

	lobby = MPAPI._internal.create_detached_lobby(lobby_data, function()
		-- The first snapshot is in: the seat is ours and the grace has stopped.
		lobby:set_catching_up(true)
		catch_up()
	end)
	if lobby then
		-- Lost before the run went live (the client gave up, the lobby closed).
		lobby:on(MPAPI.LobbyEvent.DISCONNECTED, abort)
	end
end
