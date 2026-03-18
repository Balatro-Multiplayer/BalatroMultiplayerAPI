-- Forward declarations for helper functions
local create_lobby_callback
local create_lobby_object
local subscribe_all
local handle_event
local handle_metadata
local handle_own_state
local handle_player_info
local populate_initial_players
local cleanup_lobby

-----------------------------
-- STATE VARIABLES
-----------------------------

local _current_lobby = nil

-----------------------------
-- API FUNCTIONS
-----------------------------

MPAPI.create_lobby = function(mod_id, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	if not conn or conn:get_state() ~= 'connected' then
		MPAPI.sendWarnMessage('create_lobby: not connected')
		return nil
	end

	if not mqtt then
		MPAPI.sendWarnMessage('create_lobby: MQTT not available')
		return nil
	end

	local lobby = create_lobby_object({
		mod_id = mod_id,
		player_id = conn.player_id,
		mqtt = mqtt,
		api = conn.api,
		connection = conn,
	})

	_current_lobby = lobby

	conn.api:create_lobby(conn.jwt_token, mod_id, opts.max_players, create_lobby_callback)

	return lobby
end

MPAPI.join_lobby = function(mod_id, code, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	if not conn or conn:get_state() ~= 'connected' then
		MPAPI.sendWarnMessage('join_lobby: not connected')
		return nil
	end

	if not mqtt then
		MPAPI.sendWarnMessage('join_lobby: MQTT not available')
		return nil
	end

	local lobby = create_lobby_object({
		mod_id = mod_id,
		player_id = conn.player_id,
		mqtt = mqtt,
		api = conn.api,
		connection = conn,
	})

	_current_lobby = lobby

	conn.api:join_lobby(conn.jwt_token, code, join_lobby_callback)

	return lobby
end

MPAPI.get_current_lobby = function()
	return _current_lobby
end

-----------------------------
-- INTERNAL FUNCTIONS
-----------------------------

MPAPI._internal.create_reconnected_lobby = function(lobby_data)
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()

	if not conn or not mqtt then
		return
	end

	local lobby = create_lobby_object({
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

	populate_initial_players(lobby, lobby_data.players)
	subscribe_all(lobby)
	_current_lobby = lobby
	lobby:_fire('connected')
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

join_lobby_callback = function(err, data)
	if err then
		_current_lobby:_fire('error', err)
		return
	end

	_current_lobby._connection.jwt_token = data.token

	_current_lobby.code = data.lobby.code
	_current_lobby.is_host = data.lobby.isHost or false
	_current_lobby.max_players = data.lobby.maxPlayers or 16
	_current_lobby._metadata = data.lobby.metadata or {}

	populate_initial_players(_current_lobby, data.lobby.players)
	subscribe_all(_current_lobby)
	_current_lobby:_fire('connected')
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(_current_lobby)
	end
end

create_lobby_callback = function(err, data)
	if err then
		_current_lobby:_fire('error', err)
		return
	end

	_current_lobby._connection.jwt_token = data.token

	_current_lobby.code = data.lobby.code
	_current_lobby.is_host = true
	_current_lobby.max_players = data.lobby.maxPlayers or 16
	_current_lobby._metadata = data.lobby.metadata or {}

	populate_initial_players(_current_lobby, data.lobby.players)
	subscribe_all(_current_lobby)
	_current_lobby:_fire('connected')
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(_current_lobby)
	end
end

create_lobby_object = function(opts)
	local lobby = {
		code = opts.code,
		mod_id = opts.mod_id,
		is_host = opts.is_host or false,
		max_players = opts.max_players or 16,
		player_id = opts.player_id,
		_mqtt = opts.mqtt,
		_api = opts.api,
		_connection = opts.connection,
		_metadata = opts.metadata or {},
		_player_state = nil,
		_players = {},
		_event_handlers = {},
		_destroyed = false,
	}

	function lobby:on(event_name, handler)
		if not self._event_handlers[event_name] then
			self._event_handlers[event_name] = {}
		end
		local handlers = self._event_handlers[event_name]
		handlers[#handlers + 1] = handler
	end

	function lobby:_fire(event_name, ...)
		local handlers = self._event_handlers[event_name]
		if not handlers then
			return
		end
		for _, handler in ipairs(handlers) do
			local ok, err = pcall(handler, ...)
			if not ok then
				MPAPI.sendWarnMessage('Lobby event "' .. event_name .. '" handler error: ' .. tostring(err))
			end
		end
	end

	function lobby:set_metadata(tbl)
		if self._destroyed then
			return
		end
		if not self.is_host then
			self:_fire('error', 'Only the host can set metadata')
			return
		end
		self._api:set_lobby_metadata(self._connection.jwt_token, self.code, tbl, function(err, data)
			if err then
				self:_fire('error', err)
				return
			end
			if data and data.metadata then
				self._metadata = data.metadata
			end
		end)
	end

	function lobby:get_metadata()
		return self._metadata
	end

	function lobby:set_player_state(tbl)
		if self._destroyed then
			return
		end
		local topic = self._mqtt:lobby_topic(self.code, 'players/' .. self.player_id .. '/state')
		self._mqtt:publish(topic, MPAPI.json_encode(tbl), 1, true)
		self._player_state = tbl
	end

	function lobby:get_player_state()
		return self._player_state
	end

	function lobby:get_players()
		local result = {}
		for _, player in pairs(self._players) do
			result[#result + 1] = player
		end
		return result
	end

	function lobby:leave()
		if self._destroyed then
			return
		end
		self._api:leave_lobby(self._connection.jwt_token, self.code, function(err, data)
			if err then
				self:_fire('error', err)
				return
			end
			if data and data.token then
				self._connection.jwt_token = data.token
			end
			cleanup_lobby(self)
			self:_fire('disconnected')
			if MPAPI._internal.on_lobby_disconnected then
				MPAPI._internal.on_lobby_disconnected()
			end
		end)
	end

	lobby._pending_actions = {}

	lobby._action_types = {}
	for _, key in ipairs(MPAPI.ActionType.obj_buffer) do
		local at = MPAPI.ActionTypes[key]
		if at.mod and at.mod.id == lobby.mod_id then
			lobby._action_types[key] = at
		end
	end

	function lobby:action(action_type)
		return MPAPI._internal.create_action_instance(self, action_type)
	end

	return lobby
end

subscribe_all = function(lobby)
	if not lobby._mqtt or not lobby.code then
		return
	end

	local events_topic = lobby._mqtt:lobby_topic(lobby.code, 'events')
	lobby._mqtt:subscribe(events_topic, 1, function(topic, payload)
		handle_event(lobby, payload)
	end)

	local metadata_topic = lobby._mqtt:lobby_topic(lobby.code, 'metadata')
	lobby._mqtt:subscribe(metadata_topic, 1, function(topic, payload)
		handle_metadata(lobby, payload)
	end)

	local state_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/state')
	lobby._mqtt:subscribe(state_topic, 1, function(topic, payload)
		handle_own_state(lobby, payload)
	end)

	local info_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/+/info')
	lobby._mqtt:subscribe(info_topic, 1, function(topic, payload)
		handle_player_info(lobby, topic, payload)
	end)

	local actions_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/+/actions')
	lobby._mqtt:subscribe(actions_topic, 1, function(topic, payload)
		MPAPI._internal.handle_action(lobby, topic, payload)
	end)
end

handle_event = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data or not data.type then
		return
	end

	local event_type = data.type

	if event_type == 'player_joined' then
		if data.playerId then
			lobby._players[data.playerId] = lobby._players[data.playerId] or {}
			lobby._players[data.playerId].id = data.playerId
			lobby._players[data.playerId].displayName = data.displayName
			lobby._players[data.playerId].is_away = false
		end
		lobby:_fire('player_joined', data.playerId)
	elseif event_type == 'player_left' then
		if data.playerId then
			lobby._players[data.playerId] = nil
		end
		lobby:_fire('player_left', data.playerId)
	elseif event_type == 'player_disconnected' then
		if data.playerId and lobby._players[data.playerId] then
			lobby._players[data.playerId].is_away = true
		end
		lobby:_fire('player_disconnected', data.playerId)
	elseif event_type == 'player_reconnected' then
		if data.playerId and lobby._players[data.playerId] then
			lobby._players[data.playerId].is_away = false
		end
		lobby:_fire('player_reconnected', data.playerId)
	elseif event_type == 'metadata_changed' then
		if data.data then
			lobby._metadata = data.data
		end
		lobby:_fire('metadata_changed', lobby._metadata)
	elseif event_type == 'host_changed' then
		if data.playerId then
			lobby.is_host = (data.playerId == lobby.player_id)
		end
		lobby:_fire('host_changed', data.playerId)
	elseif event_type == 'lobby_closed' then
		cleanup_lobby(lobby)
		lobby:_fire('disconnected')
		if MPAPI._internal.on_lobby_disconnected then
			MPAPI._internal.on_lobby_disconnected()
		end
	end
end

handle_metadata = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	lobby._metadata = data
	lobby:_fire('metadata_changed', lobby._metadata)
end

handle_own_state = function(lobby, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	lobby._player_state = data
end

handle_player_info = function(lobby, topic, payload)
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
			lobby:_fire('player_left', player_id)
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

	if is_new then
		lobby:_fire('player_joined', player_id)
	end
	lobby:_fire('player_info', player_id, lobby._players[player_id])
end

populate_initial_players = function(lobby, players)
	if not players then
		return
	end
	for _, p in ipairs(players) do
		if p.id then
			lobby._players[p.id] = {
				id = p.id,
				displayName = p.displayName,
				preferredJoker = p.preferredJoker,
				is_away = false,
			}
		end
	end
end

cleanup_lobby = function(lobby)
	if lobby._destroyed then
		return
	end
	lobby._destroyed = true

	if lobby._mqtt and lobby.code then
		lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'events'))
		lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'metadata'))
		lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/state'))
		lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'players/+/info'))
		lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'players/+/actions'))
	end

	lobby._pending_actions = {}

	if _current_lobby == lobby then
		_current_lobby = nil
	end
end
