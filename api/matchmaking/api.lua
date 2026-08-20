MPAPI.matchmaking = MPAPI.matchmaking or {}

-- Queue for a single mode. Returns a handle, or nil if not connected.
--
-- opts.ranked (or opts.lobby_type == MPAPI.LobbyType.RANKED) is an explicit
-- signal the caller sets - there's no way to infer ranked-ness from
-- game_mode/modId alone (see domain/lobby_type.lua and
-- gamemode/definition.lua's has_ranked_mode, which only says a mode *can*
-- have a ranked variant, not that this particular call is for it). When
-- set, this refuses to queue at all unless the launcher's anti-cheat
-- supervision channel is active and currently healthy
-- (anticheat/launcher_channel.lua) - the mod-side half of "the game
-- confirms ranked mode when connecting to a lobby". A Casual launch (or the
-- game started outside BET entirely) never sets MPAPI.anticheat.active, so
-- this only ever blocks a genuine ranked queue attempt made without a
-- supervising launcher; every non-ranked queue() call is unaffected.
--
-- Unlike the plain "not connected" guard below (bare nil - nothing was ever
-- attempted), a refused ranked attempt still returns a real handle that
-- fires MPAPI.MatchmakingEvent.ERROR (kind = ANTICHEAT_REQUIRED) on the next
-- tick - same contract a server-side queue_matchmaking failure already gets
-- further down this function - so a caller that always does
-- `local h = queue(opts); h:on('error', fn)` gets one consistent, listenable
-- signal instead of having to separately guard against a silent nil. The
-- fire is deferred a tick (not inline here) so that :on('error', fn) call
-- has a chance to run first - same deferred-event convention
-- create_local_lobby (api/lobby/public.lua) uses for its own synchronous
-- CONNECTED. Never added to mm.handles: no server-side queue entry exists
-- for it, so there's nothing for leave()/dispatch to ever reach.
MPAPI.matchmaking.queue = function(opts)
	local mm = MPAPI._internal.mm
	local conn = MPAPI.get_connection()
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendWarnMessage('[mmdbg] matchmaking.queue: not connected (conn=' .. tostring(conn ~= nil) .. ' state=' .. tostring(conn and conn:get_state()) .. ')')
		return nil
	end

	local wants_ranked = opts.ranked or opts.lobby_type == MPAPI.LobbyType.RANKED

	-- Heuristic-only integration check: MPAPI cannot trust an arbitrary
	-- game_mode string's contents (see this function's own doc comment on
	-- why ranked-ness can't be inferred), so this never blocks anything -
	-- only a real opts.ranked/opts.lobby_type gets the gate below. But a
	-- game_mode that LOOKS like it encodes "ranked" (e.g. a "ranked:" key
	-- prefix, a convention some consuming mods use for their own
	-- leaderboard/pool separation) while wants_ranked is false is a strong
	-- smell that a mod author meant to set the flag and forgot - exactly
	-- the failure mode that let a ranked-looking queue attempt skip the
	-- anti-cheat gate entirely in practice. Surfaced here, in the same
	-- debug log a mod author is already watching during their own testing,
	-- rather than staying silent until someone notices anti-cheat wasn't
	-- actually enforced.
	if not wants_ranked and type(opts.game_mode) == 'string' and opts.game_mode:lower():find('ranked', 1, true) then
		MPAPI.sendWarnMessage('[mmdbg] matchmaking.queue: game_mode "' .. opts.game_mode .. '" (mod='
			.. tostring(opts.mod_id) .. ') looks ranked but opts.ranked/opts.lobby_type was not set - the '
			.. 'launcher anti-cheat gate was NOT applied to this queue attempt. If this is really a ranked '
			.. 'queue, pass ranked=true or lobby_type=MPAPI.LobbyType.RANKED explicitly.')
	end

	local anticheat_ok = false
	if wants_ranked then
		local A = MPAPI.anticheat
		anticheat_ok = A ~= nil and A.active and A.launcher_connected and not A.launcher_supervision_lost
		if not anticheat_ok then
			local reason = 'no active/healthy launcher anti-cheat supervision (active=' .. tostring(A and A.active)
				.. ' launcher_connected=' .. tostring(A and A.launcher_connected)
				.. ' supervision_lost=' .. tostring(A and A.launcher_supervision_lost) .. ')'
			MPAPI.sendWarnMessage('matchmaking.queue: refusing a ranked queue attempt - ' .. reason)

			local handle = MPAPI.matchmaking._make_handle(opts.mod_id, opts.game_mode)
			G.E_MANAGER:add_event(Event({
				func = function()
					handle:_fire(MPAPI.MatchmakingEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.ANTICHEAT_REQUIRED, reason))
					return true
				end,
			}))
			return handle
		end
	end

	MPAPI.sendDebugMessage('[mmdbg] matchmaking.queue mod=' .. tostring(opts.mod_id) .. ' gameMode=' .. tostring(opts.game_mode) .. ' min=' .. tostring(opts.min_players) .. ' max=' .. tostring(opts.max_players))

	mm.ensure_subscribed()

	local handle = MPAPI.matchmaking._make_handle(opts.mod_id, opts.game_mode)
	mm.handles[#mm.handles + 1] = handle

	conn.api:queue_matchmaking(conn.jwt_token, {
		modId = opts.mod_id,
		gameMode = opts.game_mode,
		minPlayers = opts.min_players,
		maxPlayers = opts.max_players,
		-- Lets the (future) server independently see the same anti-cheat
		-- status the local gate above already enforced - only meaningful
		-- (and only ever true) for a ranked attempt; omitted otherwise so
		-- non-ranked queue requests keep their existing wire shape exactly.
		anticheatActive = wants_ranked and anticheat_ok or nil,
	}, function(err, data)
		if err then
			MPAPI.sendWarnMessage('[mmdbg] queue_matchmaking API error: ' .. tostring(err))
			mm.remove_handle(handle)
			handle:_fire(MPAPI.MatchmakingEvent.ERROR, err)
			return
		end
		MPAPI.sendDebugMessage('[mmdbg] queue_matchmaking OK position=' .. tostring(data and data.position))
		-- Start the shared queue-time display (idempotent; self-terminates when no
		-- handle is still searching). Every consumer mod gets it for free.
		if mm.queue_timer then mm.queue_timer.start() end
		handle:_fire(MPAPI.MatchmakingEvent.QUEUED, data and data.position)
	end)

	return handle
end

-- Queue for multiple modes simultaneously. Returns array of handles.
MPAPI.matchmaking.queue_all = function(modes)
	local handles = {}
	for _, mode in ipairs(modes) do
		local h = MPAPI.matchmaking.queue(mode)
		if h then
			handles[#handles + 1] = h
		end
	end
	return handles
end

-- Leave all active queues.
MPAPI.matchmaking.leave_all = function()
	local mm = MPAPI._internal.mm
	local conn = MPAPI.get_connection()
	if not conn then
		return
	end

	-- Clear local handles first
	local old = mm.handles
	mm.handles = {}
	mm.subscribed = false

	-- Mark all as left
	for _, h in ipairs(old) do
		h._left = true
	end

	-- Tell server to leave all queues
	conn.api:leave_all_matchmaking_queues(conn.jwt_token, function(err)
		if err then
			MPAPI.sendWarnMessage('leave_all_matchmaking_queues error: ' .. tostring(err))
		end
	end)

	-- Unsubscribe MQTT
	local mqtt = MPAPI.get_mqtt()
	if mqtt then
		mqtt:unsubscribe(mm.topic(conn.player_id))
	end
end

-- Queue the entire private lobby as a group. Only callable by the lobby host.
MPAPI.matchmaking.queue_group = function(opts)
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		MPAPI.sendWarnMessage('matchmaking.queue_group: not in a lobby')
		return nil
	end

	-- queue() will detect the lobbyCode from the session server-side
	return MPAPI.matchmaking.queue(opts)
end

-- Fetch a rating for a given mode. season may be nil to use the active
-- season. player_id may be nil to fetch the local player's own rating
-- (ratings are already fully public via get_leaderboard's entries array, so
-- fetching an arbitrary other player's -- e.g. a current lobby opponent's --
-- is just as unrestricted server-side).
MPAPI.matchmaking.get_rating = function(mod_id, game_mode, season, player_id, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_matchmaking_rating(conn.jwt_token, mod_id, game_mode, season, player_id, callback)
end

-- Fetch leaderboard for a given mode. season may be nil to use the active season.
MPAPI.matchmaking.get_leaderboard = function(mod_id, game_mode, season, opts, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	opts = opts or {}
	conn.api:get_matchmaking_leaderboard(
		conn.jwt_token,
		mod_id,
		game_mode,
		season,
		opts.limit or 100,
		opts.offset or 0,
		callback
	)
end

-- Live "N queued / M in game" counts per gameMode for mod_id. callback(err, data)
-- where data = { modId, gameModes = { [game_mode] = { queued, inMatch }, ... } }
-- (a gameMode absent from gameModes means 0/0). Most callers want
-- MPAPI.matchmaking.create_queue_counts_poller (queue_counts_poller.lua)
-- instead of calling this directly on a timer themselves.
MPAPI.matchmaking.get_queue_counts = function(mod_id, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_matchmaking_queue_counts(conn.jwt_token, mod_id, callback)
end
