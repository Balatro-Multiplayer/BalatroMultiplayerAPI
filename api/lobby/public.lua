-- Public lobby entry points: create, join, and the async server callbacks that
-- finish wiring a lobby once the server responds.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

local create_lobby_callback
local join_lobby_callback

MPAPI.create_lobby = function(mod_id, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendWarnMessage('create_lobby: not connected')
		return nil
	end

	if not mqtt then
		MPAPI.sendWarnMessage('create_lobby: MQTT not available')
		return nil
	end

	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = conn.player_id,
		mqtt = mqtt,
		api = conn.api,
		connection = conn,
	})

	L.current = lobby

	conn.api:create_lobby(conn.jwt_token, mod_id, opts.max_players, create_lobby_callback)

	return lobby
end

-- Create a lobby that exists only on this client: no server lobby is ever
-- allocated and no MQTT topics are subscribed. It satisfies the same interface as
-- a networked lobby (metadata, players, actions, gamemode instance, leave) but
-- everything is handled in-process. Use this for solo flows (e.g. practice) so
-- there is no server-side lobby that can be orphaned if the client never leaves.
MPAPI.create_local_lobby = function(mod_id, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local player_id = (conn and conn.player_id) or 'local_player'

	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = player_id,
		mqtt = MPAPI.get_mqtt and MPAPI.get_mqtt() or nil,
		api = conn and conn.api or nil,
		connection = conn,
		is_host = true,
		max_players = opts.max_players or 1,
		metadata = opts.metadata or {},
		local_mode = true,
	})

	-- Register ourselves as the only player.
	lobby._players[player_id] = {
		id = player_id,
		displayName = (conn and conn.display_name) or 'You',
		is_away = false,
	}

	L.current = lobby

	-- Mirror the async create/join callbacks: fire 'connected' on the next event
	-- tick so the caller can attach handlers (setup_lobby_events, on('connected'))
	-- before they run.
	G.E_MANAGER:add_event(Event({
		func = function()
			if L.current == lobby and not lobby._destroyed then
				lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
				if MPAPI._internal.on_lobby_connected then
					MPAPI._internal.on_lobby_connected(lobby)
				end
			end
			return true
		end,
	}))

	return lobby
end

MPAPI.join_lobby = function(mod_id, code, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	MPAPI.sendDebugMessage('[mmdbg] join_lobby mod=' .. tostring(mod_id) .. ' code=' .. tostring(code))

	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendWarnMessage('[mmdbg] join_lobby: not connected (state=' .. tostring(conn and conn:get_state()) .. ')')
		return nil
	end

	if not mqtt then
		MPAPI.sendWarnMessage('[mmdbg] join_lobby: MQTT not available')
		return nil
	end

	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = conn.player_id,
		mqtt = mqtt,
		api = conn.api,
		connection = conn,
	})

	L.current = lobby

	conn.api:join_lobby(conn.jwt_token, code, join_lobby_callback)

	return lobby
end

MPAPI.get_current_lobby = function()
	return L.current
end

MPAPI._internal.create_reconnected_lobby = function(lobby_data)
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	if not conn or not mqtt then
		return
	end

	local lobby = L.create_object({
		code = lobby_data.code,
		mod_id = lobby_data.modId,
		is_host = lobby_data.isHost or false,
		max_players = lobby_data.maxPlayers,
		player_id = conn.player_id,
		mqtt = mqtt,
		api = conn.api,
		connection = conn,
		metadata = lobby_data.metadata or {},
	})

	L.populate_initial_players(lobby, lobby_data.players)
	L.subscribe_all(lobby)
	L.current = lobby
	lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end

join_lobby_callback = function(err, data)
	local lobby = L.current
	if err then
		MPAPI.sendWarnMessage('[mmdbg] join_lobby_callback ERROR: ' .. tostring(err))
		lobby:_fire(MPAPI.LobbyEvent.ERROR, err)
		return
	end

	lobby._connection.jwt_token = data.token

	lobby.code = data.lobby.code
	lobby.is_host = data.lobby.isHost or false
	lobby.max_players = data.lobby.maxPlayers or 16
	lobby._metadata = data.lobby.metadata or {}

	MPAPI.sendDebugMessage('[mmdbg] join_lobby_callback OK code=' .. tostring(lobby.code) .. ' is_host=' .. tostring(lobby.is_host) .. ' players=' .. tostring(data.lobby.players and #data.lobby.players))
	L.populate_initial_players(lobby, data.lobby.players)
	L.subscribe_all(lobby)
	MPAPI.sendDebugMessage('[mmdbg] join_lobby_callback subscribed, firing connected')
	lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end

create_lobby_callback = function(err, data)
	local lobby = L.current
	if err then
		lobby:_fire(MPAPI.LobbyEvent.ERROR, err)
		return
	end

	lobby._connection.jwt_token = data.token

	lobby.code = data.lobby.code
	lobby.is_host = true
	lobby.max_players = data.lobby.maxPlayers or 16
	lobby._metadata = data.lobby.metadata or {}

	L.populate_initial_players(lobby, data.lobby.players)
	L.subscribe_all(lobby)
	lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end
