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

function api_client:leave_lobby(token, code, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/leave', '{}', token)
end

function api_client:set_lobby_metadata(token, code, metadata, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self.pending_callback = callback

	self.mqtt.on_http_response = function(status, body)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if not cb then
			return
		end

		if status < 200 or status >= 300 then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		cb(nil, data)
	end

	self.mqtt.on_http_error = function(msg)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if cb then
			cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
		end
	end

	local body = api_client.json_encode({ metadata = metadata })
	self.mqtt:http_put_auth(self.base_url .. '/api/lobbies/' .. code .. '/metadata', body, token)
end

function api_client:enable_chat(jwt_token, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self.pending_callback = callback

	self.mqtt.on_http_response = function(status, body)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if not cb then return end

		if status < 200 or status >= 300 then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		if data.error then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, data.error), nil)
			return
		end

		cb(nil, data)
	end

	self.mqtt.on_http_error = function(msg)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if cb then cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil) end
	end

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/chat/enable', '{}', jwt_token)
end

function api_client:send_chat_message(jwt_token, code, message, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self.pending_callback = callback

	self.mqtt.on_http_response = function(status, body)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if not cb then return end

		if status < 200 or status >= 300 then
			local ok, data = pcall(api_client.json_decode, body)
			local msg = (ok and data and data.error) or ('Server returned status ' .. tostring(status))
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, msg), nil)
			return
		end

		cb(nil, { ok = true })
	end

	self.mqtt.on_http_error = function(msg)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if cb then cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil) end
	end

	local body = api_client.json_encode({ message = message })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/chat', body, jwt_token)
end
