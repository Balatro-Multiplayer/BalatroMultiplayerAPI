-- Transport for lobbies hosted as server-authoritative Nakama matches (config
-- use_nakama_lobbies; the match is BalatroMultiplayerServer/nakama's
-- bmp_lobby). Owns the one realtime socket and the one lobby match this client
-- is in: RPCs, match join/leave, op-coded match data in and out, and socket
-- reconnect with rejoin while the server holds the seat (its grace period).
-- What the ops mean for the lobby object lives in api/lobby/nakama.lua.
--
-- The SDK socket holds a single handler per event, so every match-data and
-- disconnect callback goes through here.
local NL = {}

-- Must match nakama/src/lobby/protocol.ts.
NL.ClientOp = { LEAVE = 1, KICK = 2, SET_METADATA = 3, SET_STATE = 4, ACTION = 5 }
NL.ServerOp = {
	SNAPSHOT = 100,
	EVENT = 101,
	METADATA = 102,
	PLAYER_INFO = 103,
	ERROR = 104,
	ACTION = 105,
	ACTION_REJECTED = 106,
}
-- ACTION's `to` for an authoritative action.
NL.SERVER_TARGET = 'server'

-- Seconds between socket reconnect attempts; the last one repeats until the
-- server's grace period (LOBBY_GRACE_SECONDS, 120 by default) is surely over.
local RECONNECT_BACKOFF = { 0.5, 1, 2, 4 }
local RECONNECT_GIVE_UP_SECONDS = 130
-- Refresh the session this long before it expires.
local SESSION_REFRESH_MARGIN = 60
local DEV_DEVICE_ID_PREFIX = 'bmp-dev-'

local socket = nil
local socket_open = false
local connect_waiters = nil -- callbacks waiting on an in-flight socket connect

-- The lobby match this client is in, or nil.
local match = nil -- { id, metadata, listener, lost_since, attempt }

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
	local err = result.error
	if type(err) == 'table' then
		return err.message or fallback
	end
	return result.message or fallback
end

-- True when lobbies should go through Nakama: the flag is on and there is a
-- Nakama client to talk to (use_nakama_auth on a custom server).
function NL.enabled()
	return MPAPI.config and MPAPI.config.use_nakama_lobbies and nakama_client() ~= nil or false
end

----------------------------------------------------------------------
-- Session
----------------------------------------------------------------------

local function adopt_session(c, session)
	c.nakama_session = session
	c.nakama_client.set_bearer_token(session.token)
end

-- Dev only: impersonated logins have no Steam ticket and so no Nakama
-- session; sign in with a device id derived from the BMP player id instead.
-- The server refuses device login unless ALLOW_DEVICE_AUTH is set.
local function device_login(c, cb)
	c.nakama_client.authenticate_device(DEV_DEVICE_ID_PREFIX .. c.player_id, nil, true, nil, function(session)
		if not session or session.error then
			cb(nil, 'Nakama device login failed: ' .. error_message(session, 'no response'))
			return
		end
		adopt_session(c, session)
		cb(session)
	end)
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
	if MPAPI.config.nakama_dev_device_auth then
		device_login(c, cb)
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

local function on_match_data(message)
	local data_msg = message.match_data
	if not match or not data_msg or data_msg.match_id ~= match.id then
		return
	end
	local op = tonumber(data_msg.op_code)
	local ok, data = pcall(MPAPI.json_decode, data_msg.data or '')
	if not ok or type(data) ~= 'table' then
		MPAPI.sendWarnMessage('[nakama_lobby] bad payload for op ' .. tostring(op))
		return
	end
	match.listener.data(op, data)
end

local function on_socket_disconnect()
	socket_open = false
	socket = nil
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
		end)
	end)
end

----------------------------------------------------------------------
-- Match
----------------------------------------------------------------------

-- The per-player info the server shows everyone else (it replaces the API's
-- lobby/{code}/players/{id}/info publish). Nakama join metadata is a
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

local function lose(reason)
	local lost = match
	match = nil
	if lost and lost.listener.lost then
		lost.listener.lost(reason)
	end
end

-- After a socket drop: reconnect and rejoin the same match. A refused join
-- (lobby closed, seat already given up) ends it; a transport failure retries.
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
			if not retryable or love.timer.getTime() - this.lost_since > RECONNECT_GIVE_UP_SECONDS then
				lose(err)
				return
			end
			this.attempt = this.attempt + 1
			schedule_rejoin()
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

----------------------------------------------------------------------
-- RPC wrappers
----------------------------------------------------------------------

-- cb(err, { matchId, code })
function NL.create(mod_id, max_players, cb)
	NL.rpc('lobby_create', { modId = mod_id, maxPlayers = max_players }, cb)
end

-- cb(err, { matchId, code, modId })
function NL.find(code, cb)
	NL.rpc('lobby_find', { code = code }, cb)
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
-- Pump / teardown
----------------------------------------------------------------------

-- Fires due reconnect timers; called from MPAPI.update.
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
	match = nil
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
