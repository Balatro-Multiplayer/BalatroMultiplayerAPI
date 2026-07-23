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

		-- Pass the response body through: on a moderation rewrite it carries
		-- publishText (what other players actually received).
		local ok, data = pcall(api_client.json_decode, body)
		cb(nil, (ok and type(data) == 'table') and data or { ok = true })
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

-----------------------------
-- MODERATION INTAKE (report / appeal / mute-signal / held)
-- These feed the moderation review queue; they never gate gameplay, so they all
-- use the generic JSON callback and surface only their own success/error.
-----------------------------

-- Report another player. `report_type` is a short category ('harassment',
-- 'slur', ...); `message` is the offending text or a note (optional).
function api_client:report_player(jwt_token, code, reported_player_id, report_type, message, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	local body = api_client.json_encode({
		reportedPlayerId = reported_player_id,
		type = report_type,
		message = message,
	})
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/report', body, jwt_token)
end

-- Contest one of your own messages that moderation blocked. `original_band` is
-- the band the client recorded when the block happened (optional).
function api_client:appeal_message(jwt_token, code, message, original_band, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	local body = api_client.json_encode({ message = message, originalBand = original_band })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/appeal', body, jwt_token)
end

-- Forward the aggregate mute signal (the local mute itself is client-side).
function api_client:mute_signal(jwt_token, code, muted_player_id, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	local body = api_client.json_encode({ mutedPlayerId = muted_player_id })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/mute', body, jwt_token)
end

-- Fetch this player's held (blocked) messages for the lobby — the post-game
-- appeal screen's data. Returns { held = { { message, band, createdAt }, ... } }.
function api_client:list_held(jwt_token, code, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_json_callback(callback)

	self.mqtt:http_get_auth(self.base_url .. '/api/lobbies/' .. code .. '/held', jwt_token)
end
