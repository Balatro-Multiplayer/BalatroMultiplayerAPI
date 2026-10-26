-- Outbound action instances: the object returned by lobby:action(type), used to
-- send a directed request or broadcast to every participant.

-- Puts one envelope { cid, action, from, to, params, response_to } on the
-- lobby's match. False when it couldn't be sent.
MPAPI._internal.transmit_action = function(lobby, envelope)
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

local warned_authoritative = {}

-- Actions this client refused to send because they belong to another mod than
-- the lobby's (newest last, capped). Read by tests; see refuse_foreign_action.
MPAPI._internal.foreign_actions_dropped = MPAPI._internal.foreign_actions_dropped or {}
local FOREIGN_DROP_LOG_LIMIT = 50
local warned_foreign = {}

-- A lobby only carries its own mod's action types and MPAPI's. Another mod's
-- global hook sending into it (PvP's skip_blind location update inside an
-- SPDRN lobby) is that mod's bug, not traffic for this lobby, and in a local
-- lobby it would run the other mod's on_receive in-process.
function MPAPI._internal.action_belongs_to_lobby(lobby, action_type)
	return lobby._action_types[action_type.key] == action_type
end

local function refuse_foreign_action(lobby, action_type)
	local dropped = MPAPI._internal.foreign_actions_dropped
	dropped[#dropped + 1] = { action = action_type.key, lobby_mod = lobby.mod_id }
	if #dropped > FOREIGN_DROP_LOG_LIMIT then
		table.remove(dropped, 1)
	end
	local message = 'action ' .. tostring(action_type.key) .. ' dropped: not an action of the ' .. tostring(lobby.mod_id) .. ' lobby'
	if MPAPI._internal.dev_build and not warned_foreign[action_type.key] then
		warned_foreign[action_type.key] = true
		MPAPI.sendWarnMessage(message)
	else
		MPAPI.sendDebugMessage(message)
	end
end

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

		if not MPAPI._internal.action_belongs_to_lobby(lobby, action_type) then
			refuse_foreign_action(lobby, action_type)
			return
		end

		if action_type.authoritative then
			if lobby._local_mode then
				if not warned_authoritative[action_type.key] then
					warned_authoritative[action_type.key] = true
					MPAPI.sendWarnMessage(action_type.key .. ' needs a server lobby')
				end
				return
			end
			target_id = MPAPI.networking.nakama_lobby.SERVER_TARGET
		elseif lobby._local_mode then
			-- Offline lobby: deliver in-process instead of through the server.
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
		return sent
	end

	-- Returns false when the action was valid but the lobby's socket is down
	-- (nil when it was refused or delivered locally).
	function instance:send(target_id, params)
		return dispatch(self, target_id, params, 'send')
	end

	function instance:broadcast(params)
		dispatch(self, '*', params, 'broadcast')
	end

	return instance
end

MPAPI._internal.create_action_instance = create_action_instance
