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

-- placements = { { playerId, place, performance?, metric?, metricText? }, ... },
-- every participant once. A score board reads metricText (score text, see
-- MPAPI.BigScore) as the season best and ignores metric; a time board reads
-- metric (milliseconds). Bad metricText drops only the season best. Result params: { playerId, reported }.
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
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if lobby and type(result) == 'table' and type(result.pending) == 'boolean' then
			lobby._game.result_pending = result.pending
		end
	end,
})

-- opponentId = the contested player (a participant other than you). Any
-- participant of a matchmade game may contest its result, once: the server
-- holds the run unrated and queues it for a moderator. Result params:
-- { playerId, against }. Refusals (err.message): not_in_game, not_participant,
-- not_matchmade, already_contested, bad_params. Every client in the game gets
-- the result and fires MPAPI.LobbyEvent.CONTESTED.
MPAPI.ActionType({
	key = 'mpapi_contest',
	authoritative = true,
	parameters = {
		{ key = 'opponentId', type = 'string' },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.playerId) == 'string') then
			return
		end
		lobby:_fire(MPAPI.LobbyEvent.CONTESTED, { by = result.playerId, against = result.against })
	end,
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
		{ key = 'seq', type = 'number' },
		{ key = 'ack', type = 'boolean' },
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
-- server's log budget one token per event, as single events do. `ack = true` (on
-- this action and on mpapi_log_event) also makes the server answer the sender
-- with the request's cid and params { ack = true }.
MPAPI.ActionType({
	key = 'mpapi_log_events',
	authoritative = true,
	parameters = {
		{ key = 'events', type = 'table', required = true },
		{ key = 'ack', type = 'boolean' },
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

-- One part of a Run save (api/replay/run_save.lua). The server joins the parts and keeps the
-- latest complete save per player; it answers nobody. data holds at most
-- MPAPI.run_save.PART_BYTES characters; the limits are the server's (actions/run_save.ts).
MPAPI.ActionType({
	key = 'mpapi_run_save_part',
	authoritative = true,
	parameters = {
		{ key = 'run', type = 'string' },
		{ key = 'id', type = 'string', required = true },
		{ key = 'index', type = 'number', required = true },
		{ key = 'count', type = 'number', required = true },
		{ key = 'pos', type = 'number', required = true },
		{ key = 'hash', type = 'string', required = true },
		{ key = 'data', type = 'string', required = true },
	},
	on_receive = function() end,
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
	lobby._game.result_pending = false
	-- A restart keeps the finished steps' results (the server does too).
	local results = started.restarted and lobby._game.setup.results or {}
	lobby._game.setup = { open = nil, results = results }
	lobby:_fire(MPAPI.LobbyEvent.GAME_STARTED, lobby._game.started)
end

-- GAME_ENDED event data: { runId, status, placements }. status is 'agreed',
-- 'partial', 'disputed', 'contested' or 'abandoned' (see the server's results.ts).
L.apply_game_ended = function(lobby, ended)
	if type(ended) ~= 'table' then
		return
	end
	lobby._game.started = nil
	lobby._game.ready = {}
	lobby._game.reported = {}
	lobby._game.result_pending = false
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

-- Any participant of a matchmade game: contests its result against
-- opponent_id (may be nil in a game of 2; a larger game must name them).
-- The server holds the run unrated until a moderator decides. cb(err, result);
-- result = { playerId, against }. An older server answers 'unknown_target':
-- err.kind is then SERVER_TOO_OLD.
local OLD_SERVER_REASON = 'unknown_target'
L.contest = function(lobby, opponent_id, cb)
	ask_server(lobby, 'mpapi_contest', { opponentId = opponent_id }, cb and function(err, result)
		if err and err.kind == MPAPI.ErrorKind.ACTION_REJECTED and err.message == OLD_SERVER_REASON then
			err = MPAPI.make_error(MPAPI.ErrorKind.SERVER_TOO_OLD, localize('k_mpapi_server_too_old'))
		end
		cb(err, result)
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
-- Every event gets a number (seq, 1, 2, 3, ... per run). The server keeps an
-- event only when it holds all the ones before it, and says in the ack of a
-- batch how far it holds (got). An event stays kept here until an ack covers
-- it, and goes out again after a reconnect, after a refusal, and when no ack
-- comes. The server skips an event it already holds, so sending again is safe.
-- Without this the server's log for this player has a gap and its hash check
-- fails.
--
-- A server that sends no `got` (an older one) does not skip copies: the
-- client then treats every ack as covering its batch and never sends again.
--
-- Events leave in batches (mpapi_log_events): one message per
-- LOG_BATCH_MAX events, or fewer when their JSON passes LOG_BATCH_BYTES (the
-- server refuses a message with more than 16KB of params). A flush is also
-- deferred to the end of the frame, so a burst made in one frame goes out as
-- a few messages, not one per event. The last batch of a flush asks for the ack.
--
-- Event lists on the lobby: _unsent_log_events (not sent yet, because the
-- socket was down or a batch could not go) and _log_inflight (sent, not acked).
-- Both are in seq order, inflight first.
local LOG_BATCH_MAX = 50
local LOG_BATCH_BYTES = 12000
-- How long an unanswered batch waits before it goes out again.
local LOG_RESEND_SECONDS = 4
-- Sent events kept for a server that may never ack (an older one).
local LOG_MAX_UNCONFIRMED = 2000
L.LOG_BATCH_MAX = LOG_BATCH_MAX
L.LOG_BATCH_BYTES = LOG_BATCH_BYTES
L.LOG_RESEND_SECONDS = LOG_RESEND_SECONDS

local function event_bytes(event)
	local ok, encoded = pcall(require("json").encode, event)
	return ok and type(encoded) == 'string' and #encoded or 200
end

local function without_acked(events, got)
	if not events then
		return nil
	end
	local rest = {}
	for _, event in ipairs(events) do
		if (event.seq or 0) > got then
			rest[#rest + 1] = event
		end
	end
	return #rest > 0 and rest or nil
end

-- Moves the sent, unacked events back in front of the unsent ones.
local function requeue_inflight(lobby)
	local inflight = lobby._log_inflight
	lobby._log_inflight = nil
	if not inflight then
		return
	end
	local queue = {}
	for _, event in ipairs(inflight) do
		queue[#queue + 1] = event
	end
	for _, event in ipairs(lobby._unsent_log_events or {}) do
		queue[#queue + 1] = event
	end
	lobby._unsent_log_events = queue
end

-- Drops what the server says it holds.
local function forget_acked(lobby, got)
	lobby._log_inflight = without_acked(lobby._log_inflight, got)
	lobby._unsent_log_events = without_acked(lobby._unsent_log_events, got)
end

local arm_resend

-- When an ack does not come in LOG_RESEND_SECONDS, sends the unacked events
-- again. Only for a server known to skip copies.
arm_resend = function(lobby)
	if lobby._log_resend_armed or not lobby._log_counted or not (lobby._log_inflight or lobby._unsent_log_events) then
		return
	end
	if not (G and G.E_MANAGER and Event) then
		return
	end
	lobby._log_resend_armed = true
	local progress = lobby._log_progress or 0
	L.after_real_seconds(LOG_RESEND_SECONDS, function()
		lobby._log_resend_armed = nil
		if lobby._destroyed then
			return
		end
		if (lobby._log_progress or 0) == progress then
			requeue_inflight(lobby)
			L.flush_log_events(lobby)
		end
		arm_resend(lobby)
	end)
end

-- The server's answer to the last batch of a flush. result.got is the highest
-- seq it holds with no gap; err is a refusal. on_ack(err) is the caller's own
-- interest (a leave waits for it).
local function on_log_ack(lobby, run_id, last_seq, on_ack, result, err)
	local started = lobby._game.started
	if lobby._destroyed or not (started and started.run_id == run_id) then
		if on_ack then
			on_ack(err)
		end
		return
	end
	if err then
		arm_resend(lobby)
		if on_ack then
			on_ack(err)
		end
		return
	end
	local got = type(result) == 'table' and result.got or nil
	if type(got) ~= 'number' then
		-- The server does not count: its ack means it handled the batch.
		lobby._log_counted = false
		forget_acked(lobby, last_seq)
		if on_ack then
			on_ack(nil)
		end
		return
	end
	lobby._log_counted = true
	local before = lobby._log_acked or 0
	if got > before then
		lobby._log_acked = got
		lobby._log_progress = (lobby._log_progress or 0) + 1
	end
	forget_acked(lobby, got)
	if got < last_seq and (lobby._log_inflight or lobby._unsent_log_events) then
		-- The server lacks events this batch covers. Send them again at once
		-- while the acks move forward, else wait for the timer.
		requeue_inflight(lobby)
		if got > before then
			if not L.flush_log_events(lobby, on_ack) and on_ack then
				on_ack(nil)
			end
			return
		end
	end
	arm_resend(lobby)
	if on_ack then
		on_ack(nil)
	end
end

-- Sends one batch (a single event goes as plain mpapi_log_event); false when the socket is down
-- or the action was refused locally. With ack_for = { run_id, on_ack } the batch asks the server for an ack,
-- and on_log_ack runs when the server answers or refuses it (at once when the socket is down).
local function transmit_log_events(lobby, batch, ack_for)
	local single = #batch == 1
	local params = single and batch[1] or { events = batch }
	if ack_for then
		local asked = {}
		for k, v in pairs(params) do
			asked[k] = v
		end
		asked.ack = true
		params = asked
	end
	local action = lobby:action(MPAPI.ActionTypes[single and 'mpapi_log_event' or 'mpapi_log_events'])
	if ack_for then
		local last_seq = batch[#batch].seq or 0
		action:callback(function(_, result, err)
			on_log_ack(lobby, ack_for.run_id, last_seq, ack_for.on_ack, result, err)
		end)
	end
	-- nil means a local refusal (the params did not validate): not sent either.
	return action:send(nil, params) == true
end

-- Drops kept events of a run that is not the current one (or when no game is on).
local function keep_current_run(lobby)
	local started = lobby._game.started
	for _, field in ipairs({ '_unsent_log_events', '_log_inflight' }) do
		local kept = lobby[field]
		if kept then
			local current = {}
			for _, event in ipairs(kept) do
				if started and event.run == started.run_id then
					current[#current + 1] = event
				end
			end
			lobby[field] = #current > 0 and current or nil
		end
	end
end

-- Sends the kept events in order, in batches; stops at the first batch that
-- can't go, and keeps it and the rest for the next flush. The last batch asks
-- the server for an ack. With on_ack, on_ack(err) runs when that ack comes back;
-- the result is true when the last batch went out, so on_ack is still to come.
L.flush_log_events = function(lobby, on_ack)
	keep_current_run(lobby)
	local kept = lobby._unsent_log_events
	if not kept then
		return false
	end
	local run_id = lobby._game.started.run_id
	local sent = 0
	local inflight = lobby._log_inflight or {}
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
		local is_last = sent + #batch == #kept
		if not transmit_log_events(lobby, batch, is_last and { run_id = run_id, on_ack = on_ack } or nil) then
			break
		end
		for _, event in ipairs(batch) do
			inflight[#inflight + 1] = event
		end
		sent = sent + #batch
	end
	if lobby._log_counted == nil or lobby._log_counted == false then
		-- Not known to ack with a count: do not keep an unbounded copy.
		while #inflight > LOG_MAX_UNCONFIRMED do
			table.remove(inflight, 1)
		end
	end
	lobby._log_inflight = #inflight > 0 and inflight or nil
	if sent == #kept then
		lobby._unsent_log_events = nil
		arm_resend(lobby)
		return on_ack ~= nil
	end
	local rest = {}
	for i = sent + 1, #kept do
		rest[#rest + 1] = kept[i]
	end
	lobby._unsent_log_events = rest
	arm_resend(lobby)
	return false
end

-- The join snapshot says how many of this player's events the server holds
-- (game.logSeq). A client that starts again in the same run (a new process
-- after a crash, so no counter) numbers its next event from there; the server
-- would skip a number it already holds as a copy. A lobby that kept its
-- counter through a dropped socket keeps the higher one: what it numbered and
-- the server never got is sent again. Recording is off while a catch-up replays
-- the old events (the log opens again only when the replay is idle), so those
-- get no new numbers.
L.adopt_log_seq = function(lobby, held)
	local started = lobby._game.started
	if type(held) ~= 'number' or not started then
		return
	end
	if lobby._log_seq_run ~= started.run_id then
		lobby._log_seq_run = started.run_id
		lobby._log_seq = 0
		lobby._log_acked = 0
		lobby._log_inflight = nil
	end
	if held > lobby._log_seq then
		lobby._log_seq = held
	end
	if held > (lobby._log_acked or 0) then
		lobby._log_acked = held
	end
	forget_acked(lobby, held)
end

-- After a reconnect: what was sent and not acked may have died with the old
-- socket, so it goes out again (a server that counts skips what it holds).
L.resend_log_events = function(lobby)
	if lobby._log_counted then
		keep_current_run(lobby)
		requeue_inflight(lobby)
	end
	return L.flush_log_events(lobby)
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
	local run_id = lobby._game.started.run_id
	if lobby._log_seq_run ~= run_id then
		lobby._log_seq_run = run_id
		lobby._log_seq = 0
		lobby._log_acked = 0
		lobby._log_inflight = nil
	end
	lobby._log_seq = lobby._log_seq + 1
	local event = {
		t = t,
		opcode = opcode,
		args = args,
		run = run_id,
		seq = lobby._log_seq,
	}
	-- Behind anything already kept, so the order holds.
	local kept = lobby._unsent_log_events or {}
	kept[#kept + 1] = event
	lobby._unsent_log_events = kept
	flush_soon(lobby)
end
