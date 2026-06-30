local api_client = MPAPI.networking.api_client

function api_client:authenticate_steam(ticket, steam_name, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ ticket = ticket, steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/steam', body)
end

function api_client:authenticate_dev(steam_name, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/dev', body)
end

-- Dev-only: log in as an existing player (a real players row). target is a table
-- with one of: playerId, steamId, discordId, steamName. The server returns the same
-- auth payload as Steam auth, so the impersonated player can queue/appear ranked.
function api_client:authenticate_impersonate(target, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode(target or {})
	self.mqtt:http_post(self.base_url .. '/api/auth/dev/impersonate', body)
end

function api_client:authenticate_refresh(refresh_token, steam_name, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ refreshToken = refresh_token, steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/refresh', body)
end

function api_client:accept_tos_update(pending_token, chat_eligible, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = api_client.json_encode({ chatEligible = chat_eligible })
	self.mqtt:http_post_auth(self.base_url .. '/api/auth/accept-tos', body, pending_token)
end
