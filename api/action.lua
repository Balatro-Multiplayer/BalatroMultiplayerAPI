-----------------------------
-- ActionType registration
-----------------------------

MPAPI.ActionTypes = {}

MPAPI.ActionType = SMODS.GameObject:extend {
	obj_table = MPAPI.ActionTypes,
	obj_buffer = {},
	set = 'ActionType',
	required_params = { 'key', 'on_receive' },

	inject = function(self) end,  -- obj_table is the registry, no game tables needed
}

-----------------------------
-- Parameter validation
-----------------------------

local function validate_params(schema, params)
	if not schema then
		return nil
	end
	params = params or {}
	for _, entry in ipairs(schema) do
		if entry.required and params[entry.key] == nil then
			return 'missing required param: ' .. tostring(entry.key)
		end
		if entry.type and params[entry.key] ~= nil and type(params[entry.key]) ~= entry.type then
			return 'param "' .. tostring(entry.key) .. '" expected ' .. entry.type .. ', got ' .. type(params[entry.key])
		end
	end
	return nil
end

-----------------------------
-- Action instance
-----------------------------

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
		local err = validate_params(self._action_type.parameters, params)
		if err then
			MPAPI.sendWarnMessage('action:send validation error: ' .. err)
			return
		end

		self.params = params

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

		local topic = lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/actions')
		lobby._mqtt:publish(topic, payload, 1, false)

		local cb = self._callback
		if cb then
			lobby._pending_actions[cid] = { instance = self, callback = cb }
		end
	end

	function instance:broadcast(params)
		local err = validate_params(self._action_type.parameters, params)
		if err then
			MPAPI.sendWarnMessage('action:broadcast validation error: ' .. err)
			return
		end

		self.params = params

		local lobby = self._lobby
		local action_type = self._action_type

		local payload = MPAPI.json_encode({
			cid = MPAPI.generate_id(),
			action = action_type.key,
			from = lobby.player_id,
			to = '*',
			params = params,
		})

		local topic = lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/actions')
		lobby._mqtt:publish(topic, payload, 1, false)
	end

	return instance
end

-----------------------------
-- Inbound action handler
-----------------------------

MPAPI._internal.handle_action = function(lobby, topic, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or not data then
		return
	end

	-- Check this message is addressed to us
	if data.to ~= lobby.player_id and data.to ~= '*' then
		return
	end

	local from = topic:match('players/([^/]+)/actions$')
	if not from then
		return
	end

	-- Route responses to pending callbacks
	if data.response_to then
		local pending = lobby._pending_actions[data.response_to]
		if pending then
			lobby._pending_actions[data.response_to] = nil
			local ok2, err2 = pcall(pending.callback, pending.instance, data.params)
			if not ok2 then
				MPAPI.sendWarnMessage('action response callback error: ' .. tostring(err2))
			end
		end
		return
	end

	-- Route inbound requests
	local action_type = lobby._action_types[data.action]
	if not action_type then
		return
	end

	local err = validate_params(action_type.parameters, data.params)
	if err then
		MPAPI.sendWarnMessage('handle_action validation error for "' .. tostring(data.action) .. '": ' .. err)
		return
	end

	local ok2, result = pcall(action_type.on_receive, action_type, from, data.params)
	if not ok2 then
		MPAPI.sendWarnMessage('action on_receive error: ' .. tostring(result))
		return
	end

	-- Send response if on_receive returned a table
	if type(result) == 'table' then
		local response_payload = MPAPI.json_encode({
			cid = MPAPI.generate_id(),
			action = data.action,
			from = lobby.player_id,
			to = from,
			response_to = data.cid,
			params = result,
		})
		local topic_out = lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/actions')
		lobby._mqtt:publish(topic_out, response_payload, 1, false)
	end
end

-- Expose instance constructor for use in lobby.lua
MPAPI._internal.create_action_instance = create_action_instance
