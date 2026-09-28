-- Lobbies hosted on Nakama (config use_nakama_lobbies): the create/join/
-- rejoin entry points and the mapping from the bmp_lobby match's ops onto the
-- lobby object. The transport is networking/nakama_lobby.lua.
--
-- A prototype: the lobby itself (roster, player info, metadata, own state,
-- host, kick, leave, disconnect/rejoin) is server-authoritative on Nakama,
-- but actions and chat still only exist on MQTT, so a Nakama lobby can't run
-- a game yet. Roster ids are Nakama user ids, and lobby.player_id is ours.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

local function NL()
	return MPAPI.networking.nakama_lobby
end

L.nakama_enabled = function()
	return NL() ~= nil and NL().enabled()
end

local warned = {}

-- One warning per feature per session, then silence.
L.warn_nakama_unsupported = function(feature)
	if warned[feature] then
		return
	end
	warned[feature] = true
	MPAPI.sendWarnMessage(feature .. ' not available on Nakama lobbies yet')
end

local function fail(lobby, message)
	lobby:_fire(MPAPI.LobbyEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(message)))
end

local function tear_down(lobby)
	if lobby._destroyed then
		return
	end
	L.cleanup(lobby)
	lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
	if MPAPI._internal.on_lobby_disconnected then
		MPAPI._internal.on_lobby_disconnected()
	end
end

local function roster_from(players)
	local roster = {}
	for _, p in ipairs(players or {}) do
		if p.id then
			roster[p.id] = {
				id = p.id,
				displayName = p.displayName,
				preferredJoker = p.preferredJoker,
				mods = p.mods,
				is_away = p.isAway or false,
			}
		end
	end
	return roster
end

-- Sets the lobby to the snapshot's state (sent on every join, including a
-- rejoin after a socket drop). On a rejoin, fires the events for whatever
-- changed while this client was away.
L.apply_snapshot = function(lobby, snapshot, announce)
	if lobby._destroyed or type(snapshot) ~= 'table' then
		return
	end
	local before = lobby._players
	local was_host = lobby.is_host
	local roster = roster_from(snapshot.players)

	lobby.code = snapshot.code or lobby.code
	lobby.max_players = snapshot.maxPlayers or lobby.max_players
	lobby.type = snapshot.type or 'private'
	lobby.is_host = snapshot.hostId == lobby.player_id
	lobby._metadata = type(snapshot.metadata) == 'table' and snapshot.metadata or {}
	lobby._player_state = snapshot.ownState
	lobby._players = roster

	if not announce then
		return
	end
	for id in pairs(before) do
		if not roster[id] then
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, id)
		end
	end
	for id, player in pairs(roster) do
		if not before[id] then
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_JOINED, id)
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_INFO, id, player)
		end
	end
	if lobby.is_host ~= was_host then
		lobby:_fire(MPAPI.LobbyEvent.HOST_CHANGED, snapshot.hostId)
	end
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

local function on_data(lobby, on_ready, op, data)
	if lobby._destroyed then
		return
	end
	local ServerOp = NL().ServerOp
	if op == ServerOp.SNAPSHOT then
		local first = not lobby._nakama_ready
		L.apply_snapshot(lobby, data, not first)
		if first then
			lobby._nakama_ready = true
			on_ready(lobby)
		end
	elseif op == ServerOp.EVENT then
		L.apply_event(lobby, data)
	elseif op == ServerOp.METADATA then
		L.apply_metadata(lobby, data)
	elseif op == ServerOp.PLAYER_INFO then
		if type(data.playerId) == 'string' then
			L.apply_player_info(lobby, data.playerId, type(data.info) == 'table' and data.info or nil)
		end
	elseif op == ServerOp.ERROR then
		fail(lobby, data.message or 'Lobby error')
	end
end

local function connected(lobby)
	lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end

-- Joins the lobby's match; on_ready(lobby) runs on the first snapshot.
local function attach(lobby, match_id, on_ready)
	local session = MPAPI.get_nakama_session()
	lobby.player_id = session and session.user_id or lobby.player_id
	NL().join(match_id, lobby.mod_id, {
		data = function(op, data)
			on_data(lobby, on_ready, op, data)
		end,
		dropped = function()
			MPAPI.sendDebugMessage('[nakama_lobby] socket dropped, rejoining ' .. tostring(lobby.code))
		end,
		rejoined = function()
			MPAPI.sendDebugMessage('[nakama_lobby] rejoined ' .. tostring(lobby.code))
		end,
		lost = function(reason)
			MPAPI.sendWarnMessage('[nakama_lobby] lost lobby ' .. tostring(lobby.code) .. ': ' .. tostring(reason))
			tear_down(lobby)
		end,
	}, function(err)
		if err and not lobby._destroyed then
			fail(lobby, err)
		end
	end)
end

local function new_lobby(conn, mod_id, opts)
	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = nil,
		api = conn.api,
		connection = conn,
		is_host = opts.is_host,
		max_players = opts.max_players,
		type = opts.type,
		nakama = true,
	})
	L.current = lobby
	return lobby
end

local function connected_conn(what)
	local conn = MPAPI.get_connection()
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendWarnMessage(what .. ': not connected')
		return nil
	end
	return conn
end

L.nakama_create_lobby = function(mod_id, opts)
	local conn = connected_conn('create_lobby')
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, mod_id, { is_host = true, max_players = opts.max_players })
	NL().create(mod_id, opts.max_players, function(err, data)
		if lobby._destroyed then
			return
		end
		if err then
			fail(lobby, err)
			return
		end
		lobby.code = data.code
		attach(lobby, data.matchId, connected)
	end)
	return lobby
end

L.nakama_join_lobby = function(mod_id, code)
	local conn = connected_conn('join_lobby')
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, mod_id, {})
	NL().find(code, function(err, data)
		if lobby._destroyed then
			return
		end
		if err then
			fail(lobby, err)
			return
		end
		lobby.code = data.code
		attach(lobby, data.matchId, connected)
	end)
	return lobby
end

-- Rejoins the lobby lobby_current reported after a game restart
-- (lobby_data = the reconnected_lobby context, see networking/connection.lua).
-- on_ready(lobby) runs once the snapshot is in, after CONNECTED.
L.nakama_rejoin_lobby = function(lobby_data, on_ready)
	local conn = MPAPI.get_connection()
	if not conn then
		return
	end
	local lobby = new_lobby(conn, lobby_data.modId, { type = lobby_data.type })
	lobby.code = lobby_data.code
	attach(lobby, lobby_data.matchId, function(l)
		connected(l)
		if on_ready then
			on_ready(l)
		end
	end)
end

L.nakama_leave_current = function(cb)
	NL().leave_current(cb or function() end)
end

-- Checks for a lobby seat left over from before a restart; cb(lobby_data) or
-- cb(nil). lobby_data is the reconnected_lobby context the prompt reads.
L.nakama_check_current = function(cb)
	NL().current(function(err, data)
		if err or not data then
			cb(nil)
			return
		end
		cb({ nakama = true, matchId = data.matchId, code = data.code, modId = data.modId, type = MPAPI.LobbyType.PRIVATE })
	end)
end
