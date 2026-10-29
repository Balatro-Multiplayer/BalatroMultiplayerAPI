-- MPAPI's authoritative actions: the lobby flow every gamemode shares, run by
-- the Nakama lobby's server (BalatroMultiplayerServer nakama/src/actions/
-- registry.ts) instead of a host client. Each on_receive only ever sees the
-- server's result (from == MPAPI.ACTION_FROM_SERVER; see dispatch.lua).
--
-- Mods use the lobby methods (lobby:set_ready, lobby:start_game,
-- lobby:report_result, ...) and listen for PLAYER_READY_CHANGED /
-- GAME_STARTED / GAME_ENDED rather than touching these keys.
MPAPI.load_mpapi_file('api/action/registry.lua')

MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

-- Result params: { playerId, ready }.
MPAPI.ActionType({
	key = 'mpapi_ready',
	authoritative = true,
	parameters = {
		{ key = 'ready', type = 'boolean', required = true },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.playerId) == 'string') then
			return
		end
		lobby._game.ready[result.playerId] = result.ready == true or nil
		MPAPI.set_player_ready(lobby, result.playerId, result.ready == true)
	end,
})

local function on_game_started(_, _, result)
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and type(result) == 'table' and type(result.seed) == 'string') then
		return
	end
	L.apply_game_started(lobby, result)
end

-- Result params: { runId, seed, stake, options, players }.
MPAPI.ActionType({
	key = 'mpapi_start_game',
	authoritative = true,
	parameters = {
		{ key = 'stake', type = 'number' },
		{ key = 'options', type = 'table' },
		{ key = 'minPlayers', type = 'number' },
	},
	on_receive = on_game_started,
})

-- A new game on a new seed; same result shape as a start, and the same
-- GAME_STARTED (with `restarted = true`).
MPAPI.ActionType({
	key = 'mpapi_restart_game',
	authoritative = true,
	on_receive = function(at, from, result)
		if type(result) == 'table' then
			result.restarted = true
		end
		on_game_started(at, from, result)
	end,
})

-- The game ends through GAME_ENDED, which follows this result.
MPAPI.ActionType({
	key = 'mpapi_abandon_game',
	authoritative = true,
	on_receive = function() end,
})

-- placements = { { playerId, place, performance?, metric? }, ... }, every
-- participant once. Result params: { playerId, reported }.
MPAPI.ActionType({
	key = 'mpapi_report_result',
	authoritative = true,
	parameters = {
		{ key = 'placements', type = 'table', required = true },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if lobby and type(result) == 'table' and type(result.playerId) == 'string' then
			lobby._game.reported[result.playerId] = true
		end
	end,
})

-- pending = boolean, any participant. Marks the started game's result as
-- pending (or clears it): the server keeps the run open instead of starting
-- its result clock. Result params: { playerId, pending }.
MPAPI.ActionType({
	key = 'mpapi_set_result_pending',
	authoritative = true,
	parameters = {
		{ key = 'pending', type = 'boolean', required = true },
	},
	on_receive = function() end,
})

-- One replay event (api/replay/recorder.lua), stored with the run by the
-- server and passed on to the other players, who track how far each
-- player's stream has got. Result params: { playerId, t, opcode, args }.
MPAPI.ActionType({
	key = 'mpapi_log_event',
	authoritative = true,
	parameters = {
		{ key = 't', type = 'number', required = true },
		{ key = 'opcode', type = 'string', required = true },
		{ key = 'args', type = 'table' },
		{ key = 'run', type = 'string' },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.playerId) == 'string') then
			return
		end
		if result.playerId == lobby.player_id or type(result.t) ~= 'number' then
			return
		end
		local seen = MPAPI.replay._last_seen_t
		if result.t > (seen[result.playerId] or 0) then
			seen[result.playerId] = result.t
		end
	end,
})

-- Setup (api/setup.lua): every result's params are { setup = <view> }, the
-- whole Setup state after the change. mpapi_setup_state carries the server's
-- own changes (a turn or a vote that ran out of time); no client sends it.
local function on_setup(_, _, result)
	local lobby = MPAPI.get_current_lobby()
	if lobby and type(result) == 'table' then
		L.apply_setup(lobby, result.setup)
	end
end

MPAPI.ActionType({
	key = 'mpapi_setup_draft',
	authoritative = true,
	parameters = {
		{ key = 'id', type = 'string', required = true },
		{ key = 'candidates', type = 'table', required = true },
		{ key = 'poolSize', type = 'number' },
		{ key = 'keep', type = 'number' },
		{ key = 'schedule', type = 'table' },
		{ key = 'maxStake', type = 'number' },
		{ key = 'turnSeconds', type = 'number' },
	},
	on_receive = on_setup,
})

MPAPI.ActionType({
	key = 'mpapi_setup_choose',
	authoritative = true,
	parameters = {
		{ key = 'key', type = 'string', required = true },
	},
	on_receive = on_setup,
})

MPAPI.ActionType({
	key = 'mpapi_setup_vote',
	authoritative = true,
	parameters = {
		{ key = 'id', type = 'string', required = true },
		{ key = 'options', type = 'table', required = true },
		{ key = 'seconds', type = 'number' },
	},
	on_receive = on_setup,
})

MPAPI.ActionType({
	key = 'mpapi_setup_cast',
	authoritative = true,
	parameters = {
		{ key = 'option', type = 'string', required = true },
	},
	on_receive = on_setup,
})

MPAPI.ActionType({
	key = 'mpapi_setup_state',
	authoritative = true,
	on_receive = on_setup,
})

local function empty_setup()
	return { open = nil, results = {} }
end

-- Takes the server's Setup view. `received_at` times the open step's
-- msLeft, so the countdown never compares clocks with the server.
L.apply_setup = function(lobby, view, quiet)
	if type(view) ~= 'table' then
		return
	end
	lobby._game.setup = {
		open = type(view.open) == 'table' and view.open or nil,
		results = type(view.results) == 'table' and view.results or {},
		received_at = love.timer.getTime(),
	}
	if not quiet then
		lobby:_fire(MPAPI.LobbyEvent.SETUP_CHANGED, lobby._game.setup)
	end
end

-- Up to LOG_BATCH_MAX replay events in one message, in order (the same events
-- mpapi_log_event takes one by one). The server tells the others once:
-- { playerId, t, opcode, args, count } of the last event kept. A batch costs the
-- server's log budget one token per event, as single events do.
MPAPI.ActionType({
	key = 'mpapi_log_events',
	authoritative = true,
	parameters = {
		{ key = 'events', type = 'table', required = true },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.playerId) == 'string') then
			return
		end
		if result.playerId == lobby.player_id or type(result.t) ~= 'number' then
			return
		end
		local seen = MPAPI.replay._last_seen_t
		if result.t > (seen[result.playerId] or 0) then
			seen[result.playerId] = result.t
		end
	end,
})

L.apply_game_started = function(lobby, started)
	lobby._game.started = {
		run_id = started.runId,
		seed = started.seed,
		stake = started.stake,
		options = started.options,
		players = started.players,
		restarted = started.restarted or nil,
	}
	lobby._game.ready = {}
	lobby._game.reported = {}
	-- A restart keeps the finished steps' results (the server does too).
	local results = started.restarted and lobby._game.setup.results or {}
	lobby._game.setup = { open = nil, results = results }
	lobby:_fire(MPAPI.LobbyEvent.GAME_STARTED, lobby._game.started)
end

-- GAME_ENDED event data: { runId, status, placements }. status is 'agreed',
-- 'partial', 'disputed' or 'abandoned' (see the server's results.ts).
L.apply_game_ended = function(lobby, ended)
	if type(ended) ~= 'table' then
		return
	end
	lobby._game.started = nil
	lobby._game.ready = {}
	lobby._game.reported = {}
	lobby._game.setup = empty_setup()
	lobby:_fire(MPAPI.LobbyEvent.GAME_ENDED, {
		run_id = ended.runId,
		status = ended.status,
		placements = type(ended.placements) == 'table' and ended.placements or {},
	})
end

-- True when the server referees `lobby`'s games (ready, start, results,
-- replay capture): a Nakama lobby. Mods branch on this rather than on the
-- transport. Tolerates nil and bare test lobbies.
MPAPI.has_server_referee = function(lobby)
	return type(lobby) == 'table' and lobby._nakama == true
end

-- Without a server there's nobody to referee: cb gets an error straight away.
local function needs_nakama(lobby, cb)
	if lobby._nakama then
		return false
	end
	if cb then
		cb(MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'needs a Nakama lobby'))
	end
	return true
end

-- cb(err) once the server has taken (err == nil) or refused the change.
L.set_ready = function(lobby, ready, cb)
	if needs_nakama(lobby, cb) then
		return
	end
	lobby:action(MPAPI.ActionTypes.mpapi_ready)
		:callback(function(_, _, err)
			if cb then
				cb(err)
			end
		end)
		:send(nil, { ready = ready and true or false })
end

-- Sends one of these actions to the server; cb(err, result).
local function ask_server(lobby, key, params, cb)
	if needs_nakama(lobby, cb) then
		return
	end
	lobby:action(MPAPI.ActionTypes[key])
		:callback(function(_, result, err)
			if cb then
				cb(err, result)
			end
		end)
		:send(nil, params or {})
end

-- Host only, once everyone else is ready. opts = { stake?, options?,
-- min_players? }; cb(err, started) where started = { runId, seed, stake,
-- options, players }.
L.start_game = function(lobby, opts, cb)
	opts = opts or {}
	ask_server(lobby, 'mpapi_start_game', {
		stake = opts.stake,
		options = opts.options,
		minPlayers = opts.min_players,
	}, cb)
end

-- An action that ends the game. Events recorded this frame go first: the server stores no event
-- after the end.
local function ask_server_at_game_end(lobby, key, params, cb)
	L.flush_log_events(lobby)
	ask_server(lobby, key, params, cb)
end

-- Every participant reports the placements once the game is over; the
-- server ends it (GAME_ENDED) when they're all in. cb(err).
L.report_result = function(lobby, placements, cb)
	ask_server_at_game_end(lobby, 'mpapi_report_result', { placements = placements }, cb and function(err)
		cb(err)
	end)
end

-- Any participant: holds the started game open as a pending result (true) or
-- lets it settle (false). Events recorded this frame go first, like a report.
-- cb(err).
L.set_result_pending = function(lobby, pending, cb)
	local params = { pending = pending and true or false }
	ask_server_at_game_end(lobby, 'mpapi_set_result_pending', params, cb and function(err)
		cb(err)
	end)
end

-- Host only: ends the game with no result (GAME_ENDED, status 'abandoned').
L.abandon_game = function(lobby, cb)
	ask_server_at_game_end(lobby, 'mpapi_abandon_game', {}, cb and function(err)
		cb(err)
	end)
end

-- Host only: a new game on a new seed (GAME_STARTED again). cb(err, started).
L.restart_game = function(lobby, cb)
	ask_server_at_game_end(lobby, 'mpapi_restart_game', {}, cb)
end

-- Replay events for a server-refereed lobby go to the server, which keeps
-- them with the run. Only while a game is on: the server has nowhere to put
-- them otherwise.
--
-- An event that can't be sent because the socket is down is kept, and sent in
-- order once the seat is back (flush_log_events, after the rejoin snapshot).
-- Without that, the server's log for this player has a gap and its hash check
-- fails. Every send goes through transmit_log_events, so the way events leave
-- the client is changed in this one place.
--
-- Events leave in batches (mpapi_log_events): one message per
-- LOG_BATCH_MAX events, or fewer when their JSON passes LOG_BATCH_BYTES (the
-- server refuses a message with more than 16KB of params). A flush is also
-- deferred to the end of the frame, so a burst made in one frame goes out as
-- a few messages, not one per event.
local LOG_BATCH_MAX = 50
local LOG_BATCH_BYTES = 12000
L.LOG_BATCH_MAX = LOG_BATCH_MAX
L.LOG_BATCH_BYTES = LOG_BATCH_BYTES

local function event_bytes(event)
	local ok, encoded = pcall(require("json").encode, event)
	return ok and type(encoded) == 'string' and #encoded or 200
end

-- Sends one batch (a single event goes as plain mpapi_log_event); false when the socket is down.
local function transmit_log_events(lobby, batch)
	if #batch == 1 then
		return lobby:action(MPAPI.ActionTypes.mpapi_log_event):send(nil, batch[1]) ~= false
	end
	return lobby:action(MPAPI.ActionTypes.mpapi_log_events):send(nil, { events = batch }) ~= false
end

-- Drops kept events of a run that is not the current one (or when no game is on).
local function keep_current_run(lobby)
	local kept = lobby._unsent_log_events
	if not kept then
		return
	end
	local started = lobby._game.started
	local current = {}
	for _, event in ipairs(kept) do
		if started and event.run == started.run_id then
			current[#current + 1] = event
		end
	end
	lobby._unsent_log_events = #current > 0 and current or nil
end

-- Sends the kept events in order, in batches; stops at the first batch that
-- can't go, and keeps it and the rest for the next flush.
L.flush_log_events = function(lobby)
	keep_current_run(lobby)
	local kept = lobby._unsent_log_events
	if not kept then
		return
	end
	local sent = 0
	while sent < #kept do
		local batch, bytes = {}, 0
		for i = sent + 1, math.min(#kept, sent + LOG_BATCH_MAX) do
			local size = event_bytes(kept[i])
			if #batch > 0 and bytes + size > LOG_BATCH_BYTES then
				break
			end
			batch[#batch + 1] = kept[i]
			bytes = bytes + size
		end
		if not transmit_log_events(lobby, batch) then
			break
		end
		sent = sent + #batch
	end
	if sent == #kept then
		lobby._unsent_log_events = nil
		return
	end
	local rest = {}
	for i = sent + 1, #kept do
		rest[#rest + 1] = kept[i]
	end
	lobby._unsent_log_events = rest
end

-- Flushes at the end of this frame (once however many events are recorded
-- before it); at once when there is no event manager (headless tests).
-- no_delete: a run start or a return to the menu clears the event queue. A
-- cleared flush would leave _log_flush_pending set for ever, and no later
-- event would leave the client.
local function flush_soon(lobby)
	if lobby._log_flush_pending then
		return
	end
	if not (G and G.E_MANAGER and Event) then
		L.flush_log_events(lobby)
		return
	end
	lobby._log_flush_pending = true
	G.E_MANAGER:add_event(Event({
		trigger = 'immediate',
		blocking = false,
		blockable = false,
		no_delete = true,
		func = function()
			lobby._log_flush_pending = nil
			if not lobby._destroyed then
				L.flush_log_events(lobby)
			end
			return true
		end,
	}))
end

L.send_log_event = function(lobby, t, opcode, args)
	if not lobby._game.started then
		return
	end
	if args ~= nil and type(args) ~= 'table' then
		args = { args }
	end
	-- Tagged with the run, so an event still in flight when the server
	-- restarts the game isn't kept in the new run's log.
	local event = {
		t = t,
		opcode = opcode,
		args = args,
		run = lobby._game.started.run_id,
	}
	-- Behind anything already kept, so the order holds.
	local kept = lobby._unsent_log_events or {}
	kept[#kept + 1] = event
	lobby._unsent_log_events = kept
	flush_soon(lobby)
end
