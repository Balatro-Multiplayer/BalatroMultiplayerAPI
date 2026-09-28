-- Outbound action instances: the object returned by lobby:action(type), used to
-- send a directed request or broadcast to every participant.

local function actions_topic(lobby)
	return lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/actions')
end

-- Puts one envelope { cid, action, from, to, params, response_to } on the
-- lobby's transport. False when it couldn't be sent.
MPAPI._internal.transmit_action = function(lobby, envelope)
	if lobby._nakama then
		local NL = MPAPI.networking.nakama_lobby
		-- The server stamps `from` itself.
		local sent = NL.send(NL.ClientOp.ACTION, {
			cid = envelope.cid,
			action = envelope.action,
			to = envelope.to,
			params = envelope.params,
			responseTo = envelope.response_to,
		})
		if not sent then
			MPAPI.sendWarnMessage('action ' .. tostring(envelope.action) .. ' dropped: not connected to the lobby')
		end
		return sent
	end
	lobby._mqtt:publish(actions_topic(lobby), MPAPI.json_encode(envelope), 1, false)
	return true
end

local warned_authoritative = {}

local function create_action_instance(lobby, action_type)
	local instance = {
		params = nil,
		_callback = action_type.on_response,
		_action_type = action_type,
		_lobby = lobby,
	}

	-- fn(instance, params) with the response, or fn(instance, nil, err) when
	-- the server refused the action (err.kind == ErrorKind.ACTION_REJECTED).
	function instance:callback(fn)
		self._callback = fn
		return self
	end

	-- Validates and sends to target_id ('*' for everyone). An authoritative
	-- action always goes to the server, whatever the target.
	local function dispatch(self, target_id, params, verb)
		local err = MPAPI._internal.validate_action_params(self._action_type.parameters, params)
		if err then
			MPAPI.sendWarnMessage('action:' .. verb .. ' validation error: ' .. err)
			return
		end

		self.params = params
		local lobby = self._lobby
		local action_type = self._action_type

		if action_type.authoritative then
			if not lobby._nakama then
				if not warned_authoritative[action_type.key] then
					warned_authoritative[action_type.key] = true
					MPAPI.sendWarnMessage(action_type.key .. ' needs a Nakama lobby')
				end
				return
			end
			target_id = MPAPI.networking.nakama_lobby.SERVER_TARGET
		elseif lobby._local_mode then
			-- Offline lobby: deliver in-process instead of over the broker.
			MPAPI._internal.dispatch_local_action(self, target_id)
			return
		end

		local cid = MPAPI.generate_id()
		local sent = MPAPI._internal.transmit_action(lobby, {
			cid = cid,
			action = action_type.key,
			from = lobby.player_id,
			to = target_id,
			params = params,
		})

		-- A broadcast has no single responder, except the server's result.
		local cb = self._callback
		if cb and (verb == 'send' or action_type.authoritative) then
			if sent then
				lobby._pending_actions[cid] = { instance = self, callback = cb }
			else
				local ok, cb_err = pcall(cb, self, nil, MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'not connected to the lobby'))
				if not ok then
					MPAPI.sendWarnMessage('action response callback error: ' .. tostring(cb_err))
				end
			end
		end
	end

	function instance:send(target_id, params)
		dispatch(self, target_id, params, 'send')
	end

	function instance:broadcast(params)
		dispatch(self, '*', params, 'broadcast')
	end

	return instance
end

MPAPI._internal.create_action_instance = create_action_instance
