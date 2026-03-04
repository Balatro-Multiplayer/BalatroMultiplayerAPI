-- MQTT network thread
-- Receives commands on tx_channel, sends events on rx_channel.
-- luamqtt runs in natural blocking sync mode with moderate timeout.

local tx_channel, rx_channel = ... -- passed from main thread

-- Read setup message: package paths
local setup = tx_channel:demand() -- blocks until available
local pkg_path, pkg_cpath = setup:match('^setup\1(.*)\1(.*)$')
if pkg_path then
	package.path = pkg_path
end
if pkg_cpath then
	package.cpath = pkg_cpath
end

local SEP = '\1'
local socket = require('socket')
local mqtt = require('mqtt')
require('love.timer') -- not loaded by default in Love2D threads

-- Optionally load OpenSSL connector
local openssl_connector
pcall(function()
	require('openssl_ffi')
	openssl_connector = require('mqtt.openssl_connector')
end)

local client = nil -- luamqtt client instance
local connected = false
local running = true

-- Push an event to the main thread
local function push_event(...)
	local parts = { ... }
	rx_channel:push(table.concat(parts, SEP))
end

-- Monkey-patch _receive_packet on a client so that timeout errors
-- return the string "timeout" instead of (false, "...timeout..."),
-- which _io_iteration handles gracefully.
local function patch_receive_packet(cl)
	local mt = getmetatable(cl)
	local orig = mt.__index._receive_packet
	cl._receive_packet = function(self)
		local packet, err = orig(self)
		if packet == false and err and err:find('timeout') then
			return 'timeout'
		end
		return packet, err
	end
end

-- Set up luamqtt event handlers that push events to rx_channel
local function setup_handlers(cl)
	cl:on({
		connect = function(connack)
			if connack.rc ~= 0 then
				connected = false
				push_event('error', 'Connection failed: ' .. tostring(connack:reason_string()))
				return
			end
			connected = true
			push_event('connected')
		end,

		message = function(msg)
			cl:acknowledge(msg)
			push_event('message', msg.topic, msg.payload)
		end,

		subscribe = function()
			-- SUBACK received; we don't track per-topic here
		end,

		error = function(err)
			push_event('error', tostring(err))
		end,

		close = function()
			connected = false
			push_event('disconnected')
		end,
	})
end

-- Handle an HTTP POST request
local function handle_http_post(url, body)
	local http = require('socket.http')
	local ltn12 = require('ltn12')
	local response_body = {}
	local result, status = http.request({
		url = url,
		method = 'POST',
		headers = {
			['Content-Type'] = 'application/json',
			['Content-Length'] = tostring(#body),
		},
		source = ltn12.source.string(body),
		sink = ltn12.sink.table(response_body),
	})
	if result then
		push_event('http_response', tostring(status), table.concat(response_body))
	else
		push_event('http_error', tostring(status))
	end
end

-- Handle an HTTP POST request with Authorization: Bearer header
local function handle_http_post_auth(url, body, token)
	local http = require('socket.http')
	local ltn12 = require('ltn12')
	local response_body = {}
	local result, status = http.request({
		url = url,
		method = 'POST',
		headers = {
			['Content-Type'] = 'application/json',
			['Content-Length'] = tostring(#body),
			['Authorization'] = 'Bearer ' .. token,
		},
		source = ltn12.source.string(body),
		sink = ltn12.sink.table(response_body),
	})
	if result then
		push_event('http_response', tostring(status), table.concat(response_body))
	else
		push_event('http_error', tostring(status))
	end
end

-- Handle a connect command
local function handle_connect(broker, port, secure, client_id, keep_alive, verify, username, password)
	if client then
		pcall(function()
			client:disconnect()
		end)
		client = nil
		connected = false
	end

	local uri = broker .. ':' .. port
	local client_opts = {
		uri = uri,
		id = client_id,
		clean = true,
		keep_alive = tonumber(keep_alive) or 60,
	}

	-- Set auth credentials if provided (non-empty strings)
	if username and username ~= '' then
		client_opts.username = username
	end
	if password and password ~= '' then
		client_opts.password = password
	end

	if secure == 'true' then
		if openssl_connector then
			client_opts.connector = openssl_connector
			client_opts.secure = true
		else
			client_opts.secure = true
		end
	end

	local cl = mqtt.client(client_opts)
	setup_handlers(cl)
	client = cl

	local ok, err = cl:start_connecting()
	if not ok then
		push_event('error', 'Connect failed: ' .. tostring(err))
		client = nil
		return
	end
	-- Set a moderate timeout so _sync_iteration blocks briefly then
	-- returns, giving us a chance to check for new commands.
	local conn = cl.connection
	if conn and cl.args.connector then
		cl.args.connector.settimeout(conn, 0.05)
	end

	-- Patch _receive_packet so timeout is non-fatal
	patch_receive_packet(cl)
end

-- Handle a subscribe command
local function handle_subscribe(topic, qos)
	if not client or not connected then
		return
	end
	client:subscribe({ topic = topic, qos = tonumber(qos) or 1 })
	push_event('subscribed', topic)
end

-- Handle a publish command
local function handle_publish(topic, payload, qos, retain)
	if not client or not connected then
		return
	end
	client:publish({
		topic = topic,
		payload = payload,
		qos = tonumber(qos) or 1,
		retain = (retain == 'true'),
	})
end

-- Handle a disconnect command
local function handle_disconnect()
	if client then
		pcall(function()
			client:disconnect()
		end)
		connected = false
		client = nil
	end
end

-- Parse and dispatch a command string
local function dispatch_command(cmd)
	local parts = {}
	for part in (cmd .. SEP):gmatch('(.-)' .. SEP) do
		parts[#parts + 1] = part
	end

	local action = parts[1]
	if action == 'connect' then
		handle_connect(parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], parts[8], parts[9])
	elseif action == 'subscribe' then
		handle_subscribe(parts[2], parts[3])
	elseif action == 'publish' then
		handle_publish(parts[2], parts[3], parts[4], parts[5])
	elseif action == 'http_post' then
		handle_http_post(parts[2], parts[3])
	elseif action == 'http_post_auth' then
		handle_http_post_auth(parts[2], parts[3], parts[4])
	elseif action == 'disconnect' then
		handle_disconnect()
	elseif action == 'shutdown' then
		handle_disconnect()
		running = false
	end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
while running do
	-- 1. Drain all pending commands (non-blocking)
	while true do
		local cmd = tx_channel:pop()
		if not cmd then
			break
		end
		dispatch_command(cmd)
		if not running then
			break
		end
	end

	if not running then
		break
	end

	-- 2. Drive MQTT I/O
	if client and client.connection then
		local ok, err = pcall(function()
			client:_sync_iteration()
		end)
		-- On iteration error, report
		if not ok and err then
			push_event('error', tostring(err))
		end

		-- 3. Send PINGREQ if keep_alive interval is reached
		--    (_sync_iteration doesn't check this; only _ioloop_iteration does)
		if connected and client.args and client.send_time then
			local elapsed = os.time() - client.send_time
			if elapsed >= client.args.keep_alive then
				pcall(function()
					client:send_pingreq()
				end)
			end
		end
	else
		-- No active connection
		love.timer.sleep(0.01)
	end
end
