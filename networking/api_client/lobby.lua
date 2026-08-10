local api_client = MPAPI.networking.api_client

function api_client:create_lobby(token, mod_id, max_players, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ modId = mod_id, maxPlayers = max_players })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies', body, token)
end

function api_client:join_lobby(token, code, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/join', '{}', token)
end

-- §22.3: which live lobbies are currently spectatable (GET /api/lobbies/spectatable) --
-- the discovery step a "Spectate" browser needs. Returns {lobbies = [{code, modId, playerCount}, ...]}.
function api_client:list_spectatable(token, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(self.base_url .. '/api/lobbies/spectatable', token)
end

function api_client:leave_lobby(token, code, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/leave', '{}', token)
end

-- Response is just {ok: true}, no refreshed token (unlike leave_lobby) -- uses
-- the generic token-less JSON callback, same rationale as account.lua's
-- mute_player/unmute_player.
function api_client:kick_player(token, code, target_id, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/kick/' .. target_id, '{}', token)
end

function api_client:set_lobby_metadata(token, code, metadata, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	local body = api_client.json_encode({ metadata = metadata })
	self.mqtt:http_put_auth(self.base_url .. '/api/lobbies/' .. code .. '/metadata', body, token)
end

function api_client:enable_chat(jwt_token, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_enqueue(function(status, body)
		if status < 200 or status >= 300 then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		if data.error then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, data.error), nil)
			return
		end

		callback(nil, data)
	end, function(msg)
		callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
	end)

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/chat/enable', '{}', jwt_token)
end

function api_client:send_chat_message(jwt_token, code, message, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_enqueue(function(status, body)
		if status < 200 or status >= 300 then
			local ok, data = pcall(api_client.json_decode, body)
			local emsg = (ok and data and data.error) or ('Server returned status ' .. tostring(status))
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, emsg), nil)
			return
		end

		callback(nil, { ok = true })
	end, function(msg)
		callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
	end)

	local body = api_client.json_encode({ message = message })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/chat', body, jwt_token)
end
