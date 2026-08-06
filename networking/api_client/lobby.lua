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
			-- Only a decoded { error = "..." } body is genuine player-facing
			-- copy (chat.lua's k_chat_not_sent guard shows it verbatim). A
			-- non-JSON or bare-status response -- a proxy error page, an
			-- unexpected 5xx with no body -- carries no usable reason, so it's
			-- TRANSPORT rather than SERVER: the caller falls back to its own
			-- clean message instead of leaking this raw text to the player.
			local ok, data = pcall(api_client.json_decode, body)
			if ok and data and data.error then
				callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, data.error), nil)
			else
				callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Server returned status ' .. tostring(status)), nil)
			end
			return
		end

		-- Pass the response body through: on a moderation rewrite it carries
		-- publishText (what other players actually received).
		local ok, data = pcall(api_client.json_decode, body)
		callback(nil, (ok and type(data) == 'table') and data or { ok = true })
	end, function(msg)
		callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
	end)

	local body = api_client.json_encode({ message = message })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/chat', body, jwt_token)
end
