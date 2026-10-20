-- Inbound lobby message handlers: update the lobby's player/metadata state
-- from a message and fire the corresponding lobby event.
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

-- This client is out of `lobby` (kicked, banned, lobby closed): tear it down
-- and send the player back to the mod's menu.
function L.drop(lobby)
	L.cleanup(lobby)
	lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
	if MPAPI._internal.on_lobby_disconnected then
		MPAPI._internal.on_lobby_disconnected()
	end
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
		L.drop(lobby)
		-- A ban's removal is explained by the ban notice instead.
		local kick = type(data.data) == 'table' and data.data or nil
		if MPAPI.show_kicked_notice and not (kick and kick.reason == 'banned') then
			MPAPI.show_kicked_notice(kick)
		end
		return
	end

	if data.playerId then
		lobby._players[data.playerId] = nil
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, data.playerId)
end

local function on_lobby_closed(lobby)
	L.drop(lobby)
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
	-- Nakama lobbies only (api/action/builtin.lua).
	[MPAPI.LobbyEvent.GAME_ENDED] = function(lobby, data)
		L.apply_game_ended(lobby, data.data)
	end,
}

-- apply_*: update the lobby from a decoded match message (api/lobby/nakama.lua)
-- and fire the matching lobby events.

L.apply_event = function(lobby, data)
	if lobby._destroyed or type(data) ~= 'table' or not data.type then
		return
	end

	local handler = EVENT_HANDLERS[data.type]
	if handler then
		handler(lobby, data)
	end
end

L.apply_metadata = function(lobby, data)
	if lobby._destroyed or type(data) ~= 'table' then
		return
	end

	lobby._metadata = data
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

-- info nil: the player is gone.
L.apply_player_info = function(lobby, player_id, info)
	if lobby._destroyed then
		return
	end

	if not info then
		if lobby._players[player_id] then
			lobby._players[player_id] = nil
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, player_id)
		end
		return
	end

	local is_new = not lobby._players[player_id]
	lobby._players[player_id] = lobby._players[player_id] or {}
	lobby._players[player_id].id = player_id
	lobby._players[player_id].displayName = info.displayName
	lobby._players[player_id].preferredJoker = info.preferredJoker
	-- May be nil/absent (only present once that player's client has sent
	-- its installed mods, Nakama's profile_set_mods) -- the Lobby Info
	-- overlay's Mods tab treats absence as "no mod data available yet".
	lobby._players[player_id].mods = info.mods
	-- The server's standing for that player (domain/standing.lua); nil
	-- until it has one.
	local standing_before = lobby._players[player_id].standing
	lobby._players[player_id].standing = info.standing

	if is_new then
		lobby:_fire(MPAPI.LobbyEvent.PLAYER_JOINED, player_id)
	end
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_INFO, player_id, lobby._players[player_id])
	if not is_new and info.standing ~= standing_before then
		lobby:_fire(MPAPI.LobbyEvent.PLAYER_STANDING_CHANGED, player_id, info.standing, standing_before)
	end
end
