local api_client = {}

function api_client.new(mqtt_client, base_url)
	local self = {
		mqtt = mqtt_client,
		base_url = base_url,
		pending_callback = nil,
	}
	setmetatable(self, { __index = api_client })
	return self
end

local function json_encode(tbl)
	if json and json.encode then
		return json.encode(tbl)
	end
	local j = require('json')
	return j.encode(tbl)
end

local function json_decode(str)
	if json and json.decode then
		return json.decode(str)
	end
	local j = require('json')
	return j.decode(str)
end

-- Set up HTTP response/error handlers that parse JSON and invoke callback(err, data)
function api_client:_setup_http_callback(callback)
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
			cb('Server returned status ' .. tostring(status) .. ': ' .. body, nil)
			return
		end

		local ok, data = pcall(json_decode, body)

		if not ok or not data then
			cb('Failed to parse server response', nil)
			return
		end

		if not data.token then
			cb(data.error or 'Server response missing token', nil)
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
			cb('HTTP request failed: ' .. tostring(msg), nil)
		end
	end
end

function api_client:authenticate_steam(ticket, steam_name, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = json_encode({ ticket = ticket, steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/steam', body)
end

function api_client:authenticate_refresh(refresh_token, steam_name, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = json_encode({ refreshToken = refresh_token, steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/refresh', body)
end

function api_client:get_discord_link_url(jwt_token, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
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
			cb('Server returned status ' .. tostring(status) .. ': ' .. body, nil)
			return
		end

		local ok, data = pcall(json_decode, body)
		if not ok or not data then
			cb('Failed to parse server response', nil)
			return
		end

		if not data.url then
			cb(data.error or 'Server response missing URL', nil)
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
			cb('HTTP request failed: ' .. tostring(msg), nil)
		end
	end

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/link/discord', '{}', jwt_token)
end

function api_client:unlink_discord(jwt_token, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
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
			cb('Server returned status ' .. tostring(status) .. ': ' .. body, nil)
			return
		end

		local ok, data = pcall(json_decode, body)
		if not ok or not data then
			cb('Failed to parse server response', nil)
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
			cb('HTTP request failed: ' .. tostring(msg), nil)
		end
	end

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/unlink/discord', '{}', jwt_token)
end

function api_client:set_display_name_pref(jwt_token, use_discord_name, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = json_encode({ useDiscordName = use_discord_name })
	self.mqtt:http_post_auth(self.base_url .. '/api/auth/preferences/display-name', body, jwt_token)
end

function api_client:set_preferred_joker(jwt_token, preferred_joker, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = json_encode({ preferredJoker = preferred_joker })
	self.mqtt:http_post_auth(self.base_url .. '/api/auth/preferences/joker', body, jwt_token)
end

function api_client:accept_tos_update(pending_token, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/auth/accept-tos', '{}', pending_token)
end

function api_client:create_lobby(token, mod_id, max_players, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local body = json_encode({ modId = mod_id, maxPlayers = max_players })
	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies', body, token)
end

function api_client:join_lobby(token, code, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/join', '{}', token)
end

function api_client:leave_lobby(token, code, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	self.mqtt:http_post_auth(self.base_url .. '/api/lobbies/' .. code .. '/leave', '{}', token)
end

function api_client:set_lobby_metadata(token, code, metadata, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
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
			cb('Server returned status ' .. tostring(status) .. ': ' .. body, nil)
			return
		end

		local ok, data = pcall(json_decode, body)
		if not ok or not data then
			cb('Failed to parse server response', nil)
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
			cb('HTTP request failed: ' .. tostring(msg), nil)
		end
	end

	local body = json_encode({ metadata = metadata })
	self.mqtt:http_put_auth(self.base_url .. '/api/lobbies/' .. code .. '/metadata', body, token)
end

MPAPI.networking.api_client = api_client
