-- Dev overrides: This file (and the dev/ directory) is stripped from release builds by CI.
local api_client = MPAPI.modules.api_client
local connection = MPAPI.modules.connection

function api_client.authenticate_impersonate(self, steam_name, callback)
	if not self.mqtt or not self.mqtt.tx_channel then
		callback('MQTT thread not running', nil)
		return
	end

	self:_setup_http_callback(callback)

	local json_encode = (json and json.encode) and json.encode or require('json').encode
	local body = json_encode({ steamName = steam_name })
	self.mqtt:http_post(self.base_url .. '/api/auth/dev/impersonate', body)
end

function connection._try_impersonate_auth(self, steam_name)
	self.mqtt:start_thread()

	self.api:authenticate_impersonate(steam_name, function(err, data)
		if err then
			MPAPI.sendWarnMessage('Impersonate failed: ' .. tostring(err) .. ', falling back to Steam')
			self:_try_steam_auth()
			return
		end

		self:_handle_auth_success(data)
	end)
end

function connection._start_auth(self)
	self:_try_impersonate_auth('Bean')
end

MPAPI.sendDebugMessage('Dev auth overrides applied')
