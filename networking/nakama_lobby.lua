-- Transport for lobbies hosted as server-authoritative Nakama matches (the
-- match is BalatroMultiplayerServer/nakama's bmp_lobby). Owns the one realtime socket and the one lobby match this client
-- is in: RPCs, match join/leave, op-coded match data in and out, and socket
-- reconnect with rejoin while the server holds the seat (its grace period).
-- What the ops mean for the lobby object lives in api/lobby/nakama.lua.
--
-- The SDK socket holds a single handler per event, so every match-data and
-- disconnect callback goes through here.
local NL = {}

-- Must match nakama/src/lobby/protocol.ts.
NL.ClientOp = { LEAVE = 1, KICK = 2, SET_METADATA = 3, SET_STATE = 4, ACTION = 5, CATCHING_UP = 6 }
NL.ServerOp = {
	SNAPSHOT = 100,
	EVENT = 101,
	METADATA = 102,
	PLAYER_INFO = 103,
	ERROR = 104,
	ACTION = 105,
	ACTION_REJECTED = 106,
	CHAT = 107,
	SPECTATE_SNAPSHOT = 108,
	SPECTATE_EVENT = 109,
	SERVER_RESTARTING = 110,
	REPLAY_TAIL = 111,
	-- The lobby's group queue changed (nakama/src/lobby/group_queue.ts).
	GROUP_QUEUE = 112,
}
-- ACTION's `to` for an authoritative action.
NL.SERVER_TARGET = 'server'

-- Seconds between socket reconnect attempts; the last one repeats until the
-- server's grace period (LOBBY_GRACE_SECONDS, 120 by default) is surely over.
local RECONNECT_BACKOFF = { 0.5, 1, 2, 4 }
-- The client gives up this long after the server's grace period: the server
-- sends the grace in every snapshot (Snapshot.graceSeconds). Until the first
-- snapshot arrives, the server's default is assumed.
local DEFAULT_GRACE_SECONDS = 120
local RECONNECT_GIVE_UP_MARGIN_SECONDS = 10
-- Refresh the session this long before it expires.
local SESSION_REFRESH_MARGIN = 60

local socket = nil
local socket_open = false
local connect_waiters = nil -- callbacks waiting on an in-flight socket connect

-- The lobby match this client is in, or nil.
local match = nil -- { id, metadata, listener, lost_since, attempt }

-- The lobby match this client watches as a spectator, or nil. Kept apart from
-- `match`: watching doesn't take a seat, so it can't clash with the lobby (or
-- rejoin) this client is in.
local spectating = nil -- { id, listener }

local timers = {} -- { at, fn }

-- The SDK runs a callback-less call as a coroutine await; these are
-- fire-and-forget.
local function ignore() end

local function after(seconds, fn)
	timers[#timers + 1] = { at = love.timer.getTime() + seconds, fn = fn }
end

local function conn()
	return MPAPI.get_connection()
end

local function nakama_client()
	local c = conn()
	return c and c.nakama_client or nil
end

local function error_message(result, fallback)
	if type(result) ~= 'table' then
		return fallback
	end
	-- A failed RPC comes back as {error = {stackTrace}, message, code}: the
	-- server's refusal is the top-level message, not one inside error.
	local err = result.error
	return (type(err) == 'table' and err.message) or result.message or fallback
end

----------------------------------------------------------------------
-- Session
----------------------------------------------------------------------

local function adopt_session(c, session)
	c.nakama_session = session
	c.nakama_client.set_bearer_token(session.token)
end

local function refresh_session(c, cb)
	local session = c.nakama_session
	local client = c.nakama_client
	-- The refresh endpoint wants the server key, not the (expiring) bearer.
	client.set_bearer_token(nil)
	client.session_refresh(session.refresh_token, nil, function(refreshed)
		if not refreshed or refreshed.error then
			client.set_bearer_token(session.token)
			if os.time() < session.expires then
				cb(session)
			else
				cb(nil, 'Nakama session refresh failed: ' .. error_message(refreshed, 'no response'))
			end
			return
		end
		adopt_session(c, refreshed)
		cb(refreshed)
	end)
end

-- Calls cb(session) with a usable session, or cb(nil, message).
local function with_session(cb)
	local c = conn()
	if not c or not c.nakama_client or not c.player_id then
		cb(nil, 'Not connected')
		return
	end
	local session = c.nakama_session
	if session then
		if session.refresh_token and session.expires - os.time() < SESSION_REFRESH_MARGIN then
			refresh_session(c, cb)
		else
			cb(session)
		end
		return
	end
	cb(nil, 'No Nakama session')
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

-- Calls a server RPC with a JSON body. cb(err_message, decoded_response).
function NL.rpc(id, body, cb)
	with_session(function(session, err)
		if not session then
			cb(err)
			return
		end
		nakama_client().rpc_func(id, MPAPI.json_encode(body or {}), nil, function(result)
			if not result or result.error then
				cb(error_message(result, 'RPC ' .. id .. ' failed'))
				return
			end
			local ok, data = pcall(MPAPI.json_decode, result.payload or '{}')
			if not ok or type(data) ~= 'table' then
				cb('RPC ' .. id .. ' returned bad JSON')
				return
			end
			cb(nil, data)
		end)
	end)
end

----------------------------------------------------------------------
-- Socket
----------------------------------------------------------------------

local schedule_rejoin

-- Matchmaker tickets this client has open: ticket -> on_matched(match_id).
local tickets = {}
-- Tickets the server dropped with the socket (it keeps none across a
-- disconnect), handed to MPAPI.matchmaking once a socket is open again.
local lost_tickets = {}
-- Party tickets this client is matched by: ticket -> on_matched(match_id).
-- The party's leader holds the ticket, but every member is matched by it.
-- Kept apart from `tickets`: they are not this client's to withdraw or
-- requeue, and a dropped socket takes the party (and the ticket) with it.
local party_tickets = {}
-- The party events' listener (api/matchmaking/group/): fn(kind, message)
-- with kind 'party', 'presence' or 'leader'.
local party_listener = nil

local function on_matchmaker_matched(message)
	local matched = message.matchmaker_matched
	local ticket = matched and matched.ticket
	local fn = ticket and (tickets[ticket] or party_tickets[ticket])
	if not fn then
		return
	end
	tickets[ticket] = nil
	party_tickets[ticket] = nil
	-- Nakama sends an empty match id when the server's matched hook refused.
	local match_id = matched.match_id
	fn(match_id ~= '' and match_id or nil)
end

local function party_event(kind)
	return function(message)
		if party_listener then
			party_listener(kind, message)
		end
	end
end

local function on_match_data(message)
	local data_msg = message.match_data
	if not data_msg then
		return
	end
	local target = (match and data_msg.match_id == match.id and match)
		or (spectating and data_msg.match_id == spectating.id and spectating)
	if not target then
		return
	end
	local op = tonumber(data_msg.op_code)
	local ok, data = pcall(MPAPI.json_decode, data_msg.data or '')
	if not ok or type(data) ~= 'table' then
		MPAPI.sendWarnMessage('[nakama_lobby] bad payload for op ' .. tostring(op))
		return
	end
	target.listener.data(op, data)
end

-- Ends spectating without a word to the server; listener.lost(reason).
local function stop_spectating(reason)
	local watched = spectating
	spectating = nil
	if watched and watched.listener.lost then
		watched.listener.lost(reason)
	end
end

local keep_open = false
local keep_open_attempt = 0
local reopen_socket

local function on_socket_disconnect()
	socket_open = false
	socket = nil
	-- Nothing to rejoin: a spectator holds no seat, and the snapshot a
	-- rewatch would get can't replay the events missed meanwhile.
	stop_spectating('Connection lost')
	for id in pairs(tickets) do
		lost_tickets[#lost_tickets + 1] = id
	end
	tickets = {}
	party_tickets = {}
	if party_listener then
		party_listener('socket_lost', {})
	end
	if (keep_open or #lost_tickets > 0) and not match then
		reopen_socket()
	end
	if match and not match.lost_since then
		match.lost_since = love.timer.getTime()
		match.attempt = 1
		if match.listener.dropped then
			match.listener.dropped()
		end
		schedule_rejoin()
	end
end

local function flush_waiters(ok, err)
	local waiters = connect_waiters or {}
	connect_waiters = nil
	for _, cb in ipairs(waiters) do
		cb(ok, err)
	end
end

-- Calls cb(true) once the socket is open, or cb(false, message).
local function with_socket(cb)
	if socket and socket_open then
		cb(true)
		return
	end
	if connect_waiters then
		connect_waiters[#connect_waiters + 1] = cb
		return
	end
	connect_waiters = { cb }
	with_session(function(session, err)
		if not session then
			flush_waiters(false, err)
			return
		end
		local s = nakama_client().create_socket()
		s.on_match_data(on_match_data)
		s.on_matchmaker_matched(on_matchmaker_matched)
		s.on_party(party_event('party'))
		s.on_party_presence_event(party_event('presence'))
		s.on_party_leader(party_event('leader'))
		s.on_notifications(function(message)
			MPAPI.networking.nakama_notify.dispatch(message)
		end)
		s.on_error(function(message)
			MPAPI.sendWarnMessage('[nakama_lobby] socket error: ' .. error_message(message, '?'))
		end)
		s.on_disconnect(function()
			if socket == s then
				on_socket_disconnect()
			end
		end)
		socket = s
		s.connect(function(ok, message)
			if socket ~= s then
				return
			end
			socket_open = ok and true or false
			if not ok then
				socket = nil
			end
			flush_waiters(socket_open, message)
			if socket_open and #lost_tickets > 0 then
				local lost = lost_tickets
				lost_tickets = {}
				if MPAPI.matchmaking and MPAPI.matchmaking._on_nakama_tickets_lost then
					MPAPI.matchmaking._on_nakama_tickets_lost(lost)
				end
			end
		end)
	end)
end

-- cb(ok, err) once the socket is open.
NL.ensure_socket = function(cb)
	with_socket(cb or ignore)
end

-- The socket carries the server's pushes, so it is reopened after a drop
-- even outside a lobby (a lobby rejoin reopens it anyway).
reopen_socket = function()
	keep_open_attempt = keep_open_attempt + 1
	local delay = RECONNECT_BACKOFF[math.min(keep_open_attempt, #RECONNECT_BACKOFF)]
	after(delay, function()
		local wanted = keep_open or #lost_tickets > 0
		if not wanted or socket or match then
			return
		end
		with_socket(function(ok)
			if ok then
				keep_open_attempt = 0
			elseif (keep_open or #lost_tickets > 0) and not socket and not match then
				reopen_socket()
			end
		end)
	end)
end

function NL.keep_socket_open(on)
	keep_open = on and true or false
	keep_open_attempt = 0
end

----------------------------------------------------------------------
-- Match
----------------------------------------------------------------------

-- The per-player info the server shows everyone else. Nakama join metadata is a
-- string-to-string map, so the mods list travels as JSON.
local function join_metadata(mod_id)
	local c = conn()
	local ok, mods = pcall(MPAPI.collect_installed_mods)
	return {
		modId = mod_id,
		displayName = c.display_name or c.steam_name or 'Player',
		preferredJoker = c.preferred_joker or 'j_joker',
		mods = ok and mods and MPAPI.json_encode(mods) or nil,
	}
end

local function send_join(cb)
	with_socket(function(ok, err)
		if not ok then
			cb(err or 'Could not open the Nakama socket', true)
			return
		end
		socket.match_join(match.id, nil, match.metadata, function(result)
			if result and result.error then
				cb(error_message(result, 'Could not join the lobby'), false)
				return
			end
			cb(nil)
		end)
	end)
end

-- Joins a lobby match. listener = { data(op, tbl), dropped(), rejoined(),
-- lost(reason) }; data is required, the rest optional. cb(err_message).
function NL.join(match_id, mod_id, listener, cb)
	if match then
		cb('Already in a Nakama lobby')
		return
	end
	match = { id = match_id, metadata = join_metadata(mod_id), listener = listener }
	local this = match
	send_join(function(err)
		if match ~= this then
			return
		end
		if err then
			match = nil
		end
		cb(err)
	end)
end

-- Seconds after the socket drops at which the client gives up reconnecting,
-- for a server grace period of `grace_seconds` (nil: the server's default).
-- Pure.
function NL.give_up_seconds(grace_seconds)
	local grace = tonumber(grace_seconds)
	if not grace or grace <= 0 then
		grace = DEFAULT_GRACE_SECONDS
	end
	return grace + RECONNECT_GIVE_UP_MARGIN_SECONDS
end

-- Records the server's seat grace period for the current match (from its
-- snapshot). No-op outside a match.
function NL.set_grace_seconds(grace_seconds)
	if match then
		match.grace_seconds = tonumber(grace_seconds)
	end
end

-- gave_up is true when reconnecting ran out of time (the match is over, as the
-- server will have forfeited the seat) rather than the server refusing us.
local function lose(reason, gave_up)
	local lost = match
	match = nil
	if lost and lost.listener.lost then
		lost.listener.lost(reason, gave_up == true)
	end
end

-- A refused rejoin may be a lobby the server brought back under a new match
-- after a restart (its lobby/checkpoint.ts): lobby_current names the match
-- the seat is in now. cb('moved') once `this` follows it, cb('wait') while
-- the server is still bringing it back, else cb(nil).
local function follow_seat(this, cb)
	NL.rpc('lobby_current', {}, function(err, data)
		if match ~= this then
			return
		end
		if err then
			cb('wait')
		elseif data and data.resuming then
			cb('wait')
		elseif data and data.matchId and data.matchId ~= this.id then
			this.id = data.matchId
			cb('moved')
		else
			cb(nil)
		end
	end)
end

-- After a socket drop: reconnect and rejoin the same match. A refused join
-- (lobby closed, seat already given up) ends it, unless the lobby moved to a
-- new match over a server restart; a transport failure retries.
schedule_rejoin = function()
	local this = match
	local delay = RECONNECT_BACKOFF[math.min(this.attempt, #RECONNECT_BACKOFF)]
	after(delay, function()
		if match ~= this then
			return
		end
		send_join(function(err, retryable)
			if match ~= this then
				return
			end
			if not err then
				this.lost_since = nil
				this.attempt = nil
				if this.listener.rejoined then
					this.listener.rejoined()
				end
				return
			end
			if love.timer.getTime() - this.lost_since > NL.give_up_seconds(this.grace_seconds) then
				lose(err, true)
				return
			end
			if retryable then
				this.attempt = this.attempt + 1
				schedule_rejoin()
				return
			end
			follow_seat(this, function(outcome)
				if not outcome then
					lose(err)
					return
				end
				this.attempt = outcome == 'moved' and 1 or this.attempt + 1
				schedule_rejoin()
			end)
		end)
	end)
end

-- Sends an op to the current match. Dropped while the socket is down: the
-- server only takes ops from seated players, and the snapshot on rejoin
-- carries the state that matters.
function NL.send(op, tbl)
	if not match or not socket or not socket_open or match.lost_since then
		return false
	end
	-- An empty table would encode as [].
	local data = (tbl and next(tbl)) and MPAPI.json_encode(tbl) or '{}'
	socket.match_data_send(match.id, op, data, nil, true, ignore)
	return true
end

-- Leaves on purpose; cb(err) once the server has let the seat go. Goes
-- through the lobby_leave RPC rather than the LEAVE op: the RPC only returns
-- once the match has dropped us, so a create or join straight after can't
-- find us still seated. (A match_leave would read as a disconnect.) If the
-- RPC fails, LEAVE is sent as a fallback.
function NL.leave(cb)
	local left = match
	match = nil
	if not left then
		cb(nil)
		return
	end
	NL.leave_current(function(err)
		if err and socket and socket_open then
			socket.match_data_send(left.id, NL.ClientOp.LEAVE, '{}', nil, true, ignore)
		end
		cb(err)
	end)
end

-- Leaves the match socket-wise only (match_leave): the server reads it as a
-- disconnect and, for a group queue's home lobby that is away, parks the
-- seat. Unlike NL.leave the seat is kept, so the lobby can be rejoined by
-- its code. Returns the match id left, or nil.
function NL.step_out()
	local left = match
	match = nil
	if not left then
		return nil
	end
	if socket and socket_open then
		socket.match_leave(left.id, ignore)
	end
	return left.id
end

-- Watches a lobby match without a seat (the server's lobby/spectate.ts).
-- listener = { data(op, tbl), lost(reason) }; the server sends
-- SPECTATE_SNAPSHOT first, then SPECTATE_EVENTs. cb(err_message).
-- mod_id is the watching mod's: the server refuses a spectator of another
-- mod's lobby.
function NL.spectate(match_id, mod_id, listener, cb)
	if spectating then
		cb('Already spectating a lobby')
		return
	end
	spectating = { id = match_id, listener = listener }
	local this = spectating
	with_socket(function(ok, err)
		if spectating ~= this then
			return
		end
		if not ok then
			spectating = nil
			cb(err or 'Could not open the Nakama socket')
			return
		end
		socket.match_join(match_id, nil, { role = 'spectator', modId = mod_id }, function(result)
			if spectating ~= this then
				return
			end
			if result and result.error then
				spectating = nil
				cb(error_message(result, 'Could not spectate the lobby'))
				return
			end
			cb(nil)
		end)
	end)
end

-- Stops watching. LEAVE (not match_leave): the server lets a spectator go at
-- once either way, and the op needs no reply.
function NL.unspectate()
	local watched = spectating
	spectating = nil
	if watched and socket and socket_open then
		socket.match_data_send(watched.id, NL.ClientOp.LEAVE, '{}', nil, true, ignore)
	end
end

function NL.is_spectating()
	return spectating ~= nil
end

----------------------------------------------------------------------
-- RPC wrappers
----------------------------------------------------------------------

-- cb(err, { matchId, code })
function NL.create(mod_id, max_players, cb)
	NL.rpc('lobby_create', { modId = mod_id, maxPlayers = max_players }, cb)
end

-- cb(err, { matchId, code, modId }). With mod_id, a code of another mod's
-- lobby is refused ("Lobby is for a different mod").
function NL.find(code, mod_id, cb)
	NL.rpc('lobby_find', { code = code, modId = mod_id }, cb)
end

-- The lobby this player still holds a seat in (after a game restart).
-- cb(err, { matchId, code, modId } or nil)
function NL.current(cb)
	NL.rpc('lobby_current', {}, function(err, data)
		if err or not data or not data.matchId then
			cb(err, nil)
			return
		end
		cb(nil, data)
	end)
end

-- Gives up the seat from the lobby_current record without joining.
function NL.leave_current(cb)
	NL.rpc('lobby_leave', {}, cb)
end

----------------------------------------------------------------------
-- Matchmaker
----------------------------------------------------------------------

-- Opens a matchmaker ticket. `ticket` = { min_count, max_count, query,
-- strings = {..}, numbers = {..} }. cb(err, ticket_id) runs once the server
-- has taken it; on_matched(match_id) runs when a group is found and its
-- lobby made (join it with NL.join).
function NL.queue(ticket, on_matched, cb)
	with_socket(function(ok, err)
		if not ok then
			cb(err or 'Could not open the Nakama socket')
			return
		end
		socket.matchmaker_add(
			ticket.min_count,
			ticket.max_count,
			ticket.query,
			ticket.strings,
			ticket.numbers,
			ticket.count_multiple,
			function(result)
				local id = result and result.matchmaker_ticket and result.matchmaker_ticket.ticket
				if result and result.error or not id then
					cb(error_message(result, 'Could not join the queue'))
					return
				end
				tickets[id] = on_matched
				cb(nil, id)
			end
		)
	end)
end

-- Withdraws a ticket. Quietly does nothing for one that already matched.
function NL.unqueue(ticket_id, cb)
	tickets[ticket_id] = nil
	if not (socket and socket_open) then
		if cb then
			cb()
		end
		return
	end
	socket.matchmaker_remove(ticket_id, function(result)
		if cb then
			cb(result and result.error and error_message(result, 'Could not leave the queue') or nil)
		end
	end)
end

-- Swaps a ticket for `ticket` (a wider ranked window). The old one is
-- withdrawn first; when the server no longer has it (it matched, or went with
-- the socket) nothing is added and cb(nil, nil) runs, leaving its on_matched
-- (or the lost-tickets requeue) to carry on. Otherwise as NL.queue.
function NL.requeue(old_id, ticket, on_matched, cb)
	if not (socket and socket_open) or not tickets[old_id] then
		cb(nil, nil)
		return
	end
	socket.matchmaker_remove(old_id, function(result)
		if result and result.error then
			cb(nil, nil)
			return
		end
		-- Kept until the new ticket is in, so a socket dropped meanwhile
		-- still reports it lost (and the handle queues again).
		NL.queue(ticket, on_matched, function(err, id)
			tickets[old_id] = nil
			cb(err, id)
		end)
	end)
end

function NL.unqueue_all()
	local ids = {}
	for id in pairs(tickets) do
		ids[#ids + 1] = id
	end
	for _, id in ipairs(ids) do
		NL.unqueue(id)
	end
end

----------------------------------------------------------------------
-- Parties (a group queue: api/matchmaking/group/)
----------------------------------------------------------------------

-- fn(kind, message) for the socket's party events; nil to stop.
function NL.set_party_listener(fn)
	party_listener = fn
end

-- An open party for up to `max_size`. cb(err, party) with party = { party_id,
-- self, leader, presences }.
function NL.party_create(max_size, cb)
	with_socket(function(ok, err)
		if not ok then
			cb(err or 'Could not open the Nakama socket')
			return
		end
		socket.party_create(true, max_size, function(result)
			local party = result and result.party
			if (result and result.error) or not party or not party.party_id then
				cb(error_message(result, 'Could not create the party'))
				return
			end
			cb(nil, party)
		end)
	end)
end

-- cb(err) once the server has taken (or refused) the join.
function NL.party_join(party_id, cb)
	with_socket(function(ok, err)
		if not ok then
			cb(err or 'Could not open the Nakama socket')
			return
		end
		socket.party_join(party_id, function(result)
			cb(result and result.error and error_message(result, 'Could not join the party') or nil)
		end)
	end)
end

function NL.party_leave(party_id, cb)
	cb = cb or ignore
	if not (socket and socket_open) then
		cb(nil)
		return
	end
	socket.party_leave(party_id, function(result)
		cb(result and result.error and error_message(result, 'Could not leave the party') or nil)
	end)
end

-- The leader's party ticket. `ticket` as NL.queue's. cb(err, ticket_id);
-- the ticket is not this client's own (see party_tickets), so register it
-- with NL.expect_ticket to be told of the match.
function NL.party_queue(party_id, ticket, cb)
	if not (socket and socket_open) then
		cb('Not connected')
		return
	end
	socket.party_matchmaker_add(
		party_id,
		ticket.min_count,
		ticket.max_count,
		ticket.query,
		ticket.strings,
		ticket.numbers,
		ticket.count_multiple,
		function(result)
			local id = result and result.party_matchmaker_ticket and result.party_matchmaker_ticket.ticket
			if (result and result.error) or not id then
				cb(error_message(result, 'Could not queue the party'))
				return
			end
			cb(nil, id)
		end
	)
end

function NL.party_unqueue(party_id, ticket_id, cb)
	party_tickets[ticket_id] = nil
	cb = cb or ignore
	if not (socket and socket_open) then
		cb(nil)
		return
	end
	socket.party_matchmaker_remove(party_id, ticket_id, function(result)
		cb(result and result.error and error_message(result, 'Could not withdraw the party ticket') or nil)
	end)
end

-- on_matched(match_id or nil) when the matchmaker matches `ticket_id`, a
-- party ticket this client is in; nil on_matched forgets it.
function NL.expect_ticket(ticket_id, on_matched)
	party_tickets[ticket_id] = on_matched
end

----------------------------------------------------------------------
-- Pump / teardown
----------------------------------------------------------------------

-- Runs fn after `seconds` of real time, from NL.update. Dropped by NL.reset.
function NL.after(seconds, fn)
	after(seconds, fn)
end

-- Fires due timers (reconnects, ranked window widening); called from MPAPI.update.
function NL.update()
	if #timers == 0 then
		return
	end
	local now = love.timer.getTime()
	local due = {}
	for i = #timers, 1, -1 do
		if timers[i].at <= now then
			due[#due + 1] = table.remove(timers, i)
		end
	end
	for i = #due, 1, -1 do
		due[i].fn()
	end
end

-- Forgets the match without a word to the server, which already dropped us
-- (lobby closed, kicked) or has been told (leave). The socket stays up for
-- the next lobby.
function NL.forget()
	match = nil
end

-- Forgets the match and closes the socket without telling the server
-- (connection teardown; the server treats it as a disconnect).
function NL.reset()
	keep_open = false
	match = nil
	spectating = nil
	tickets = {}
	party_tickets = {}
	lost_tickets = {}
	timers = {}
	flush_waiters(false, 'Connection closed')
	local s = socket
	socket = nil
	socket_open = false
	if s then
		s.disconnect()
	end
end

-- Test hook: drops the socket as if the network had, keeping the match so
-- the reconnect path runs.
function NL._drop_socket()
	local s = socket
	if not s then
		return
	end
	s.disconnect()
	if socket == s then
		on_socket_disconnect()
	end
end

function NL._current_match_id()
	return match and match.id or nil
end

MPAPI.networking.nakama_lobby = NL

