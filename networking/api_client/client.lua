local api_client = {}

function api_client.new(mqtt_client, base_url)
	local self = {
		mqtt = mqtt_client,
		base_url = base_url,
		-- FIFO of pending response handlers, one per in-flight request. The worker
		-- thread (mqtt_thread.lua) drains tx_channel in order and runs each HTTP
		-- request synchronously, so http_response/http_error events come back in the
		-- same order the requests were sent -- popping the front here matches each
		-- response to its request. A single shared slot (the old design) meant two
		-- overlapping requests clobbered each other: the second overwrote the first's
		-- handler, so the first response ran the wrong parser ("Failed to parse
		-- server response") and the second response was dropped. That surfaced as e.g.
		-- "Leave Queue & Continue" firing leave + join in one tick and the join failing.
		_queue = {},
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

-- Install the persistent response router on the current mqtt transport. Each
-- inbound event pops the oldest pending handler (FIFO) and dispatches to it.
--
-- Positional FIFO matching is correct because of three invariants, all true today:
--   * ordering -- the worker (mqtt_thread.lua) runs requests serially and blocks on
--     each, so responses come back in send order; the front entry is the answer.
--   * one-event-per-request -- every handle_http_* pushes exactly one response OR
--     error (request_with_retry is bounded), so each request pops exactly one entry.
--   * no in-place transport swap -- self.mqtt is set once in new(); MPAPI.reconnect
--     rebuilds a fresh api_client with a new empty _queue rather than re-pointing an
--     existing client's transport, so the queue never outlives its transport.
-- If any of those is ever broken (an in-place reconnect, a concurrent/pipelined
-- worker, a send that skips _enqueue), the queue desyncs and every later response
-- misroutes. The empty-queue branch below is a tripwire: a response with nothing
-- pending should be impossible, so warn loudly instead of failing silently.
function api_client:_install_router()
	self.mqtt.on_http_response = function(status, body)
		local entry = table.remove(self._queue, 1)
		if entry then
			entry.on_response(status, body)
		else
			MPAPI.sendWarnMessage('api_client: http_response with no pending request -- response-queue desync')
		end
	end
	self.mqtt.on_http_error = function(msg)
		local entry = table.remove(self._queue, 1)
		if entry then
			entry.on_error(msg)
		else
			MPAPI.sendWarnMessage('api_client: http_error with no pending request -- response-queue desync')
		end
	end
end

-- Enqueue a pending request's handlers. Call this immediately before sending the
-- request on the transport, so queue order matches send order.
function api_client:_enqueue(on_response, on_error)
	self:_install_router()
	self._queue[#self._queue + 1] = { on_response = on_response, on_error = on_error }
end

-- Response/error handlers that parse JSON and invoke callback(err, data), requiring
-- a `token` field in the body (used by the auth endpoints).
function api_client:_setup_http_callback(callback)
	self:_enqueue(function(status, body)
		if not callback then return end
		if status < 200 or status >= 300 then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'Server returned status ' .. tostring(status) .. ': ' .. body), nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		if not data.token then
			callback(MPAPI.make_error(MPAPI.ErrorKind.AUTH_FAILED, data.error or 'Server response missing token'), nil)
			return
		end

		callback(nil, data)
	end, function(msg)
		if callback then
			callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
		end
	end)
end

-- Generic JSON-only response handler (no token field required)
function api_client:_setup_json_callback(callback)
	self:_enqueue(function(status, body)
		if not callback then return end

		if status == 204 then
			callback(nil, nil)
			return
		end

		if status < 200 or status >= 300 then
			local ok, data = pcall(api_client.json_decode, body)
			local errMsg = (ok and data and data.error) or ('Server returned status ' .. tostring(status))
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, errMsg), nil)
			return
		end

		if body == '' or body == nil then
			callback(nil, nil)
			return
		end

		local ok, data = pcall(api_client.json_decode, body)
		if not ok or not data then
			callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'Failed to parse server response'), nil)
			return
		end

		callback(nil, data)
	end, function(msg)
		if callback then
			callback(MPAPI.make_error(MPAPI.ErrorKind.TRANSPORT, 'HTTP request failed: ' .. tostring(msg)), nil)
		end
	end)
end

MPAPI.networking.api_client = api_client
