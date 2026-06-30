local api_client = MPAPI.networking.api_client

function api_client:get_discord_link_url(jwt_token, callback)
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

		if status ~= 200 then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		if not data.url then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, data.error or 'Server response missing URL'), nil)
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

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/link/discord', '{}', jwt_token)
end

function api_client:unlink_discord(jwt_token, callback)
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

		if status ~= 200 then
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

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/unlink/discord', '{}', jwt_token)
end

function api_client:set_display_name_pref(jwt_token, use_discord_name, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ useDiscordName = use_discord_name })
	self.mqtt:http_post_auth(self.base_url .. '/api/auth/preferences/display-name', body, jwt_token)
end

function api_client:set_preferred_joker(jwt_token, preferred_joker, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ preferredJoker = preferred_joker })
	self.mqtt:http_post_auth(self.base_url .. '/api/auth/preferences/joker', body, jwt_token)
end
