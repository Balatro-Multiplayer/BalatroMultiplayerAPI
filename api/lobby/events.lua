-- Inbound lobby message handlers: decode an MQTT payload, update the lobby's
-- player/metadata state, and fire the corresponding lobby event.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

local function on_player_joined(lobby, data)
	if data.playerId then
		lobby._players[data.playerId] = lobby._players[data.playerId] or {}
		lobby._players[data.playerId].id = data.playerId
		lobby._players[data.playerId].displayName = data.displayName
		lobby._players[data.playerId].is_away = false
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_JOINED, data.playerId)
end

local function on_player_left(lobby, data)
	if data.playerId then
		lobby._players[data.playerId] = nil
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, data.playerId)
end

local function on_player_disconnected(lobby, data)
	if data.playerId and lobby._players[data.playerId] then
		lobby._players[data.playerId].is_away = true
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_DISCONNECTED, data.playerId)
end

local function on_player_reconnected(lobby, data)
	if data.playerId and lobby._players[data.playerId] then
		lobby._players[data.playerId].is_away = false
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_RECONNECTED, data.playerId)
end

local function on_metadata_changed(lobby, data)
	if data.data then
		lobby._metadata = data.data
	end
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

local function on_host_changed(lobby, data)
	if data.playerId then
		lobby.is_host = (data.playerId == lobby.player_id)
	end
	lobby:_fire(MPAPI.LobbyEvent.HOST_CHANGED, data.playerId)
end

-- If this client is the one kicked, tear the lobby down the same way
-- on_lobby_closed does (force back to the menu) and show a notice explaining
-- why. Otherwise, just drop the removed player from the roster and reuse the
-- existing PLAYER_LEFT event so ui/lobby.lua's roster-removal animation fires
-- without duplicating that logic here.
local function on_player_kicked(lobby, data)
	local was_self = data.playerId and data.playerId == lobby.player_id

	if was_self then
		L.cleanup(lobby)
		lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
		if MPAPI._internal.on_lobby_disconnected then
			MPAPI._internal.on_lobby_disconnected()
		end
		if MPAPI.show_kicked_notice then
			MPAPI.show_kicked_notice()
		end
		return
	end

	if data.playerId then
		lobby._players[data.playerId] = nil
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, data.playerId)
end

local function on_lobby_closed(lobby)
	L.cleanup(lobby)
	lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
	if MPAPI._internal.on_lobby_disconnected then
		MPAPI._internal.on_lobby_disconnected()
	end
end

local EVENT_HANDLERS = {
	[MPAPI.LobbyEvent.PLAYER_JOINED] = on_player_joined,
	[MPAPI.LobbyEvent.PLAYER_LEFT] = on_player_left,
	[MPAPI.LobbyEvent.PLAYER_KICKED] = on_player_kicked,
	[MPAPI.LobbyEvent.PLAYER_DISCONNECTED] = on_player_disconnected,
	[MPAPI.LobbyEvent.PLAYER_RECONNECTED] = on_player_reconnected,
	[MPAPI.LobbyEvent.METADATA_CHANGED] = on_metadata_changed,
	[MPAPI.LobbyEvent.HOST_CHANGED] = on_host_changed,
	[MPAPI.LobbyEvent.LOBBY_CLOSED] = on_lobby_closed,
}

L.handle_event = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data or not data.type then
		return
	end

	local handler = EVENT_HANDLERS[data.type]
	if handler then
		handler(lobby, data)
	end
end

L.handle_metadata = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	lobby._metadata = data
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

L.handle_own_state = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	lobby._player_state = data
end

L.handle_player_info = function(lobby, topic, payload)
	if lobby._destroyed then
		return
	end

	local player_id = topic:match('/players/([^/]+)/info$')
	if not player_id then
		return
	end

	if not payload or payload == '' then
		if lobby._players[player_id] then
			lobby._players[player_id] = nil
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, player_id)
		end
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	local is_new = not lobby._players[player_id]
	lobby._players[player_id] = lobby._players[player_id] or {}
	lobby._players[player_id].id = player_id
	lobby._players[player_id].displayName = data.displayName
	lobby._players[player_id].preferredJoker = data.preferredJoker
	-- May be nil/absent (only present once that player has hit
	-- POST /api/auth/preferences/mods post-connect) -- the Lobby Info
	-- overlay's Mods tab treats absence as "no mod data available yet".
	lobby._players[player_id].mods = data.mods

	if is_new then
		lobby:_fire(MPAPI.LobbyEvent.PLAYER_JOINED, player_id)
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_INFO, player_id, lobby._players[player_id])
end
