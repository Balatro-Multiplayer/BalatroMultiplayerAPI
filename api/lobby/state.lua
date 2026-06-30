-- The lobby object factory and its lifecycle state. The active lobby pointer and
-- the helpers shared across the lobby files live on MPAPI._internal.lobby so they
-- cross files without load-order coupling.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

L.create_object = function(opts)
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
		_gamemode_instance = nil,
		-- Offline lobbies have no server/MQTT backing: metadata, player state, leave
		-- and actions are all handled in-process. See MPAPI.create_local_lobby.
		_local_mode = opts.local_mode or false,
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
			self:_fire(MPAPI.LobbyEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'Only the host can set metadata'))
			return
		end
		-- Offline lobby: no server round-trip; merge locally and notify listeners.
		if self._local_mode then
			for k, v in pairs(tbl) do
				self._metadata[k] = v
			end
			self:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, self._metadata)
			return
		end
		self._api:set_lobby_metadata(self._connection.jwt_token, self.code, tbl, function(err, data)
			if err then
				self:_fire(MPAPI.LobbyEvent.ERROR, err)
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

	function lobby:get_gamemode_instance()
		return self._gamemode_instance
	end

	function lobby:set_player_state(tbl)
		if self._destroyed then
			return
		end
		if self._local_mode then
			self._player_state = tbl
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
		-- Offline lobby: nothing to tell the server; tear down locally.
		if self._local_mode then
			L.cleanup(self)
			self:_fire(MPAPI.LobbyEvent.DISCONNECTED)
			if MPAPI._internal.on_lobby_disconnected then
				MPAPI._internal.on_lobby_disconnected()
			end
			return
		end
		self._api:leave_lobby(self._connection.jwt_token, self.code, function(err, data)
			if err then
				self:_fire(MPAPI.LobbyEvent.ERROR, err)
				return
			end
			if data and data.token then
				self._connection.jwt_token = data.token
			end
			L.cleanup(self)
			self:_fire(MPAPI.LobbyEvent.DISCONNECTED)
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

L.populate_initial_players = function(lobby, players)
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

L.cleanup = function(lobby)
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
		if MPAPI.config.chat_enabled then
			lobby._mqtt:unsubscribe(lobby._mqtt:lobby_topic(lobby.code, 'chat/+'))
		end
	end

	MPAPI.chat.cleanup()

	lobby._pending_actions = {}

	if L.current == lobby then
		L.current = nil
	end
end
