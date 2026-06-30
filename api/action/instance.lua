-- Outbound action instances: the object returned by lobby:action(type), used to
-- send a directed request or broadcast to every participant.

local function actions_topic(lobby)
	return lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/actions')
end

local function create_action_instance(lobby, action_type)
	local instance = {
		params = nil,
		_callback = action_type.on_response,
		_action_type = action_type,
		_lobby = lobby,
	}

	function instance:callback(fn)
		self._callback = fn
		return self
	end

	function instance:send(target_id, params)
		local err = MPAPI._internal.validate_action_params(self._action_type.parameters, params)
		if err then
			MPAPI.sendWarnMessage('action:send validation error: ' .. err)
			return
		end

		self.params = params

		-- Offline lobby: deliver in-process instead of over the broker.
		if self._lobby._local_mode then
			MPAPI._internal.dispatch_local_action(self, target_id)
			return
		end

		local cid = MPAPI.generate_id()
		local lobby = self._lobby
		local action_type = self._action_type

		local payload = MPAPI.json_encode({
			cid = cid,
			action = action_type.key,
			from = lobby.player_id,
			to = target_id,
			params = params,
		})

		lobby._mqtt:publish(actions_topic(lobby), payload, 1, false)

		local cb = self._callback
		if cb then
			lobby._pending_actions[cid] = { instance = self, callback = cb }
		end
	end

	function instance:broadcast(params)
		local err = MPAPI._internal.validate_action_params(self._action_type.parameters, params)
		if err then
			MPAPI.sendWarnMessage('action:broadcast validation error: ' .. err)
			return
		end

		self.params = params

		-- Offline lobby: deliver in-process instead of over the broker.
		if self._lobby._local_mode then
			MPAPI._internal.dispatch_local_action(self, '*')
			return
		end

		local lobby = self._lobby
		local action_type = self._action_type

		local payload = MPAPI.json_encode({
			cid = MPAPI.generate_id(),
			action = action_type.key,
			from = lobby.player_id,
			to = '*',
			params = params,
		})

		lobby._mqtt:publish(actions_topic(lobby), payload, 1, false)
	end

	return instance
end

MPAPI._internal.create_action_instance = create_action_instance
