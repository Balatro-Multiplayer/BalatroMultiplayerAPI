-- Inbound action delivery: in-process for offline lobbies, over MQTT or a
-- Nakama match for networked ones. Both networked transports hand
-- deliver_action the same envelope.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

-- The sender id of an authoritative action's result (Nakama only).
MPAPI.ACTION_FROM_SERVER = 'server'

-- Offline lobbies have no MQTT broker, so an action is delivered to the only
-- participant -- ourselves -- synchronously, in-process. Mirrors the self/broadcast
-- branch of deliver_action below (validation already ran in send/broadcast).
MPAPI._internal.dispatch_local_action = function(instance, target_id)
	local lobby = instance._lobby
	local action_type = instance._action_type

	-- Only the local player exists; anything addressed elsewhere has no recipient.
	if target_id ~= '*' and target_id ~= lobby.player_id then
		return
	end

	local ok, result = pcall(action_type.on_receive, action_type, lobby.player_id, instance.params)
	if not ok then
		MPAPI.sendWarnMessage('action on_receive error (local): ' .. tostring(result))
		return
	end

	-- An on_receive that returns a table is a response; for a self-addressed
	-- request/response, hand it straight back to this instance's callback.
	if type(result) == 'table' and instance._callback then
		local ok2, err2 = pcall(instance._callback, instance, result)
		if not ok2 then
			MPAPI.sendWarnMessage('action response callback error (local): ' .. tostring(err2))
		end
	end
end

local function resolve_pending(lobby, cid, params, err)
	local pending = cid and lobby._pending_actions[cid]
	if not pending then
		return false
	end
	lobby._pending_actions[cid] = nil
	local ok, cb_err = pcall(pending.callback, pending.instance, params, err)
	if not ok then
		MPAPI.sendWarnMessage('action response callback error: ' .. tostring(cb_err))
	end
	return true
end

-- Delivers one inbound action. envelope = { cid, action, from, to, params,
-- response_to }, with `from` already trusted by the transport (the MQTT topic,
-- or the Nakama server's stamp).
L.deliver_action = function(lobby, envelope)
	if lobby._destroyed or type(envelope) ~= 'table' then
		return
	end

	-- Check this message is addressed to us
	if envelope.to ~= lobby.player_id and envelope.to ~= '*' then
		return
	end

	local from = envelope.from
	if type(from) ~= 'string' then
		return
	end

	-- Route responses to pending callbacks
	if envelope.response_to then
		resolve_pending(lobby, envelope.response_to, envelope.params)
		return
	end

	-- Route inbound requests
	local action_type = lobby._action_types[envelope.action]
	if not action_type then
		return
	end

	local from_server = from == MPAPI.ACTION_FROM_SERVER
	-- An authoritative action only ever arrives as the server's result.
	if (action_type.authoritative == true) ~= from_server then
		return
	end

	-- A server result has its own shape; `parameters` describes the request.
	if not from_server then
		local err = MPAPI._internal.validate_action_params(action_type.parameters, envelope.params)
		if err then
			MPAPI.sendWarnMessage('handle_action validation error for "' .. tostring(envelope.action) .. '": ' .. err)
			return
		end
	end

	local ok, result = pcall(action_type.on_receive, action_type, from, envelope.params)
	if not ok then
		MPAPI.sendWarnMessage('action on_receive error: ' .. tostring(result))
		return
	end

	-- The server's result carries the request's cid: that's the requester's
	-- response.
	if from_server then
		resolve_pending(lobby, envelope.cid, envelope.params)
		return
	end

	-- Send response if on_receive returned a table
	if type(result) == 'table' then
		MPAPI._internal.transmit_action(lobby, {
			cid = MPAPI.generate_id(),
			action = envelope.action,
			from = lobby.player_id,
			to = from,
			response_to = envelope.cid,
			params = result,
		})
	end
end

-- The server refused one of our actions (Nakama): rejection = { cid, action,
-- reason }. Its callback gets (instance, nil, err); without one, it's logged.
L.reject_action = function(lobby, rejection)
	if lobby._destroyed or type(rejection) ~= 'table' then
		return
	end
	local reason = tostring(rejection.reason or 'rejected')
	local err = MPAPI.make_error(MPAPI.ErrorKind.ACTION_REJECTED, reason)
	if not resolve_pending(lobby, rejection.cid, nil, err) then
		MPAPI.sendWarnMessage('action ' .. tostring(rejection.action) .. ' rejected: ' .. reason)
	end
end

-- MQTT: the sender is the topic's player id, never the payload's `from`.
MPAPI._internal.handle_action = function(lobby, topic, payload)
	if lobby._destroyed then
		return
	end

	local ok, data = pcall(MPAPI.json_decode, payload)
	if not ok or type(data) ~= 'table' then
		return
	end

	local from = topic:match('players/([^/]+)/actions$')
	if not from then
		return
	end

	L.deliver_action(lobby, {
		cid = data.cid,
		action = data.action,
		from = from,
		to = data.to,
		params = data.params,
		response_to = data.response_to,
	})
end
