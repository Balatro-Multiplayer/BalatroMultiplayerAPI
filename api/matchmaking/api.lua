MPAPI.matchmaking = MPAPI.matchmaking or {}

-- Queues are Nakama matchmaker tickets (the server makes the lobby, see
-- BalatroMultiplayerServer nakama/src/matchmaking).

-- How far apart two ranked ratings may be to be matched: the window starts at
-- RANKED_SPREAD_INITIAL and grows by RANKED_SPREAD_EXPAND_RATE for every
-- RANKED_SPREAD_EXPAND_SECS spent queueing, up to RANKED_SPREAD_CAP. These are
-- the pre-Nakama server's numbers and rule (apps/server features/matchmaking
-- elo.service.ts + queue.ts runRankedQueue on the mqtt branch).
MPAPI.matchmaking.RANKED_SPREAD_INITIAL = 150
MPAPI.matchmaking.RANKED_SPREAD_EXPAND_RATE = 50
MPAPI.matchmaking.RANKED_SPREAD_EXPAND_SECS = 30
MPAPI.matchmaking.RANKED_SPREAD_CAP = 600
local DEFAULT_RATING = 600

-- The ranked window after `wait_secs` in the queue. Pure.
MPAPI.matchmaking.ranked_spread = function(wait_secs)
	local M = MPAPI.matchmaking
	local steps = math.floor(math.max(0, wait_secs or 0) / M.RANKED_SPREAD_EXPAND_SECS)
	return math.min(M.RANKED_SPREAD_INITIAL + steps * M.RANKED_SPREAD_EXPAND_RATE, M.RANKED_SPREAD_CAP)
end

-- Seconds in the queue at which the ranked ticket is next swapped for a
-- fresh one: every RANKED_SPREAD_EXPAND_SECS, also once the window is at the
-- cap. A Nakama ticket searches only on its first matchmaker pass (later it is
-- only found by others' searches), so the fresh ticket is what lets a long
-- wait's wide window take in players who queued after it, as the old
-- server's oldest-entry anchor did. Pure.
MPAPI.matchmaking.next_requeue_at = function(wait_secs)
	local M = MPAPI.matchmaking
	local steps = math.floor(math.max(0, wait_secs or 0) / M.RANKED_SPREAD_EXPAND_SECS)
	return (steps + 1) * M.RANKED_SPREAD_EXPAND_SECS
end

-- The matchmaker ticket for a queue attempt. Pure. A ticket only matches
-- others asking for the same mod, mode and kind; a ranked one also only
-- ones rated within `spread` (default RANKED_SPREAD_INITIAL) of `rating`. The
-- mode is the bare board name (a 'ranked:' key prefix dropped), like the
-- rating RPCs.
MPAPI.matchmaking._nakama_ticket = function(opts, ranked, rating, spread)
	local mode = tostring(opts.game_mode):gsub('^ranked:', '')
	local kind = ranked and 'ranked' or 'casual'
	local query = string.format('+properties.modId:%s +properties.mode:%s +properties.kind:%s', opts.mod_id, mode, kind)
	local numbers
	if ranked then
		spread = spread or MPAPI.matchmaking.RANKED_SPREAD_INITIAL
		rating = rating or DEFAULT_RATING
		query = query
			.. string.format(' +properties.rating:>=%d +properties.rating:<=%d', rating - spread, rating + spread)
		numbers = { rating = rating }
	end
	return {
		min_count = opts.min_players or 2,
		max_count = opts.max_players or opts.min_players or 2,
		query = query,
		strings = { modId = opts.mod_id, mode = mode, kind = kind },
		numbers = numbers,
	}
end

-- The server keeps no ticket across a dropped socket (a network blip, or a
-- server restart): queue again, once a socket is open, for every handle whose
-- ticket went with it.
MPAPI.matchmaking._on_nakama_tickets_lost = function(lost)
	local mm = MPAPI._internal.mm
	if not mm then
		return
	end
	local gone = {}
	for _, id in ipairs(lost) do
		gone[id] = true
	end
	for _, handle in ipairs(mm.handles) do
		if handle._nakama_ticket and gone[handle._nakama_ticket] and not handle._left and handle._nakama_requeue then
			handle._nakama_ticket = nil
			MPAPI.sendDebugMessage('[matchmaking] ticket lost with the socket; queueing again')
			handle._nakama_requeue()
		end
	end
end

-- Seconds since the handle first queued (love.timer is real time, unlike the
-- game's event timers).
local function queue_wait(handle)
	return love.timer.getTime() - (handle._queued_at or love.timer.getTime())
end

local function nakama_queue(opts, handle, ranked)
	local NL = MPAPI.networking.nakama_lobby
	local function on_matched(match_id)
		MPAPI._internal.mm.on_nakama_matched(handle, match_id)
	end
	local schedule_requeue
	-- The answer to a ticket add: `first` for a fresh queue attempt (QUEUED
	-- fires), false for a fresh ticket replacing one.
	local function on_ticket(first)
		return function(err, ticket)
			if err then
				MPAPI._internal.mm.remove_handle(handle)
				handle:_fire(MPAPI.MatchmakingEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)))
				-- The server's refusal (queue ban, queue switched off) is the
				-- player's only answer to pressing QUEUE; say it on screen.
				if MPAPI.show_notice then
					MPAPI.show_notice('k_queue_failed_title', tostring(err))
				end
				return
			end
			if handle._left or handle.match_id then
				NL.unqueue(ticket)
				return
			end
			handle._nakama_ticket = ticket
			if first then
				local mm = MPAPI._internal.mm
				if mm.queue_timer then mm.queue_timer.start() end
				handle:_fire(MPAPI.MatchmakingEvent.QUEUED, nil)
			end
			if ranked then
				schedule_requeue(ticket)
			end
		end
	end
	local function open(rating)
		if handle._left then
			return
		end
		handle._nakama_rating = rating
		handle._nakama_spread = ranked and MPAPI.matchmaking.ranked_spread(queue_wait(handle)) or nil
		NL.queue(MPAPI.matchmaking._nakama_ticket(opts, ranked, rating, handle._nakama_spread), on_matched, on_ticket(true))
	end
	-- Nakama can't change a ticket's query, and a ticket searches only on its
	-- first pass, so each RANKED_SPREAD_EXPAND_SECS the ticket is swapped for a
	-- fresh one at the window reached by then (the old one is withdrawn
	-- first: one that already matched carries on to its lobby).
	-- (_requeue_floor: the step last fired, so float rounding in the clock
	-- can't count it twice.)
	schedule_requeue = function(ticket)
		local at = MPAPI.matchmaking.next_requeue_at(math.max(queue_wait(handle), handle._requeue_floor or 0))
		NL.after(math.max(0, at - queue_wait(handle)), function()
			if handle._left or handle.match_id or handle._nakama_ticket ~= ticket then
				return
			end
			handle._requeue_floor = at
			local spread = MPAPI.matchmaking.ranked_spread(math.max(queue_wait(handle), at))
			if spread > (handle._nakama_spread or 0) then
				MPAPI.sendDebugMessage('[matchmaking] widening the ranked window to +-' .. spread)
			end
			local fresh = MPAPI.matchmaking._nakama_ticket(opts, ranked, handle._nakama_rating, spread)
			NL.requeue(ticket, fresh, on_matched, function(err, new_ticket)
				if err == nil and new_ticket == nil then
					-- The old ticket was already spent (matched, or lost with
					-- the socket): its own path carries on.
					return
				end
				if not err then
					handle._nakama_spread = spread
				end
				on_ticket(false)(err, new_ticket)
			end)
		end)
	end
	local function start()
		if not ranked then
			open(nil)
			return
		end
		-- Ranked tickets carry the player's rating; an unreadable one queues at the default.
		MPAPI.matchmaking.get_rating(opts.mod_id, opts.game_mode, nil, nil, function(err, data)
			open(not err and data and tonumber(data.rating) or nil)
		end)
	end
	-- A refused match spends the ticket (api/connection/moderation.lua), as
	-- does a dropped socket (on_tickets_lost below). Queueing again keeps the
	-- time already waited, so the window doesn't shrink back.
	handle._nakama_requeue = start
	handle._nakama_ranked = ranked
	handle._queued_at = love.timer.getTime()
	start()
end

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
		if MPAPI.show_notice then
			MPAPI.show_notice('k_status_offline', localize('k_lobby_not_connected'))
		end
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

	if wants_ranked then
		local A = MPAPI.anticheat
		local anticheat_ok = A ~= nil and A.active and A.launcher_connected and not A.launcher_supervision_lost
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

	local handle = MPAPI.matchmaking._make_handle(opts.mod_id, opts.game_mode)
	mm.handles[#mm.handles + 1] = handle

	nakama_queue(opts, handle, wants_ranked and true or false)
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

	-- Mark all as left, and tell each handle's subscribers, as handle:leave()
	-- does: a consumer mod's queue UI (SPDRN's Queue/Cancel pillar) otherwise
	-- still shows the search as running.
	for _, h in ipairs(old) do
		h._left = true
	end
	for _, h in ipairs(old) do
		h:_fire('left')
	end

	MPAPI.networking.nakama_lobby.unqueue_all()
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

-- Ratings live on the Nakama server (BalatroMultiplayerServer nakama/src/rating)
-- and are read through its RPCs. Its boards are keyed by the bare mode, so a
-- queue's 'ranked:' prefix is dropped.
local function nakama_mode(game_mode)
	return (tostring(game_mode):gsub('^ranked:', ''))
end

local function nakama_rating_rpc(id, mod_id, game_mode, callback, player_id)
	local body = { modId = mod_id, mode = nakama_mode(game_mode), playerId = player_id }
	MPAPI.networking.nakama_lobby.rpc(id, body, function(err, data)
		if err then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)), nil)
			return
		end
		callback(nil, data)
	end)
end

-- Fetch a rating for a given mode. season may be nil to use the active
-- season. player_id may be nil to fetch the local player's own rating
-- (ratings are already fully public via get_leaderboard's entries array, so
-- fetching an arbitrary other player's -- e.g. a current lobby opponent's --
-- is just as unrestricted server-side).
MPAPI.matchmaking.get_rating = function(mod_id, game_mode, season, player_id, callback)
	-- player_id is a lobby roster id, which is the Nakama user id.
	nakama_rating_rpc('rating_get', mod_id, game_mode, callback, player_id)
end

-- Fetch leaderboard for a given mode. season may be nil to use the active season.
MPAPI.matchmaking.get_leaderboard = function(mod_id, game_mode, season, opts, callback)
	-- Entries sorted by rank, plus the caller's own entry.
	nakama_rating_rpc('leaderboard_get', mod_id, game_mode, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		local own = MPAPI.get_replay_player_id()
		local entries, player_entry = {}, nil
		for _, e in ipairs(data.entries or {}) do
			local entry = {
				rank = e.rank,
				playerId = e.playerId,
				displayName = e.name,
				rating = e.rating,
				wins = e.wins,
				losses = e.losses,
				gamesPlayed = e.gamesPlayed,
				seasonBest = e.seasonBest,
			}
			entries[#entries + 1] = entry
			if e.playerId == own then
				player_entry = entry
			end
		end
		callback(nil, { entries = entries, playerEntry = player_entry })
	end)
end

-- Live "N queued / M in game" counts per gameMode for mod_id. callback(err, data)
-- where data = { modId, gameModes = { [game_mode] = { queued, inMatch }, ... } }
-- (a gameMode absent from gameModes means 0/0). Most callers want
-- MPAPI.matchmaking.create_queue_counts_poller (queue_counts_poller.lua)
-- instead of calling this directly on a timer themselves.
MPAPI.matchmaking.get_queue_counts = function(mod_id, callback)
	-- Nakama queues are matchmaker tickets: the module counts them.
	MPAPI.networking.nakama_lobby.rpc('queue_counts', { modId = mod_id }, function(err, data)
		if err then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)), nil)
			return
		end
		callback(nil, data)
	end)
end
