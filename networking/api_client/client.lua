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

function api_client.json_encode(tbl)
	if json and json.encode then
		return json.encode(tbl)
	end
	local j = require('json')
	return j.encode(tbl)
end

function api_client.json_decode(str)
	if json and json.decode then
		return json.decode(str)
	end
	local j = require('json')
	return j.decode(str)
end

-- True when the MQTT worker thread is up and able to carry HTTP requests. Every
-- request method guards on this before touching the transport.
function api_client:_transport_ready()
	return self.mqtt and self.mqtt.tx_channel
end

-- Set up HTTP response/error handlers that parse JSON and invoke callback(err, data),
-- requiring a `token` field in the body (used by the auth endpoints).
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
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)

		if not ok or not data then
			cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		if not data.token then
			cb(MPAPI.make_error(MPAPI.ErrorKind.AUTH_FAILED, data.error or 'Server response missing token'), nil)
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
end

-- Generic JSON-only response handler (no token field required)
function api_client:_setup_json_callback(callback)
	self.pending_callback = callback

	self.mqtt.on_http_response = function(status, body)
		self.mqtt.on_http_response = nil
		self.mqtt.on_http_error = nil
		local cb = self.pending_callback
		self.pending_callback = nil
		if not cb then return end

		if status == 204 then
			cb(nil, nil)
			return
		end

		if status < 200 or status >= 300 then
			local ok, data = pcall(api_client.json_decode, body)
			local errMsg = (ok and data and data.error) or ('Server returned status ' .. tostring(status))
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, errMsg), nil)
			return
		end

		if body == '' or body == nil then
			cb(nil, nil)
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
		if cb then cb(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil) end
	end
end

MPAPI.networking.api_client = api_client
