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

-- HTTPS via OpenSSL FFI: forces IPv4 DNS (avoids ENETUNREACH on IPv6-less networks)
-- and wraps TCP with the same TLS layer used by MQTT.
local function do_https_request(method, url, body, extra_headers)
	local ossl = require('openssl_ffi')
	if not ossl.available() then
		return nil, 'OpenSSL not available'
	end

	local host, rest = url:match('^https://([^/]+)(.*)')
	if not host then return nil, 'invalid https url' end
	local path = (rest ~= '' and rest) or '/'
	local port = 443
	local h, p = host:match('^(.+):(%d+)$')
	if h then host, port = h, tonumber(p) end

	-- toip() calls gethostbyname — IPv4 only, avoids IPv6 ENETUNREACH
	local ip, dns_err = socket.dns.toip(host)
	if not ip then
		return nil, 'DNS: ' .. tostring(dns_err)
	end

	local sock = socket.tcp()
	sock:settimeout(15)
	local ok, conn_err = sock:connect(ip, port)
	if not ok then
		sock:close()
		return nil, 'connect: ' .. tostring(conn_err)
	end

	local fd = sock:getfd()
	if fd < 0 then sock:close(); return nil, 'no socket fd' end

	local ctx, ctx_err = ossl.new_context({ verify = false })
	if not ctx then sock:close(); return nil, 'ssl ctx: ' .. tostring(ctx_err) end

	local ssl, ssl_err = ossl.new_ssl(ctx, fd, host)
	if not ssl then
		ossl.free_context(ctx); sock:close()
		return nil, 'ssl obj: ' .. tostring(ssl_err)
	end

	local hs_ok, hs_err = ossl.connect(ssl)
	if not hs_ok then
		for _ = 1, 50 do
			if hs_err ~= 'wouldblock' then break end
			socket.sleep(0.1)
			hs_ok, hs_err = ossl.connect(ssl)
		end
	end
	if not hs_ok then
		ossl.free(ssl); ossl.free_context(ctx); sock:close()
		return nil, 'tls: ' .. tostring(hs_err)
	end

	body = body or ''
	local hdrs = { 'Host: ' .. host, 'Connection: close' }
	if #body > 0 then
		table.insert(hdrs, 'Content-Type: application/json')
		table.insert(hdrs, 'Content-Length: ' .. #body)
	end
	if extra_headers then
		for k, v in pairs(extra_headers) do
			table.insert(hdrs, k .. ': ' .. v)
		end
	end
	local request = method .. ' ' .. path .. ' HTTP/1.1\r\n' ..
		table.concat(hdrs, '\r\n') .. '\r\n\r\n' .. body

	local _, write_err = ossl.write(ssl, request)
	if write_err then
		ossl.shutdown(ssl); ossl.free(ssl); ossl.free_context(ctx); sock:close()
		return nil, 'send: ' .. tostring(write_err)
	end

	local parts = {}
	local deadline = socket.gettime() + 15
	while socket.gettime() < deadline do
		local pending = ossl.pending(ssl)
		if pending > 0 then
			local data = ossl.read(ssl, pending)
			if data then table.insert(parts, data) end
		else
			local readable = socket.select({ sock }, nil, 0.5)
			if readable and #readable > 0 then
				local data = ossl.read(ssl, 8192)
				if data then table.insert(parts, data) else break end
			end
		end
		-- Stop early once Content-Length bytes are in hand
		local acc = table.concat(parts)
		local he = acc:find('\r\n\r\n', 1, true)
		if he then
			local cl = acc:match('[Cc]ontent%-[Ll]ength: (%d+)')
			if cl and (#acc - he - 3) >= tonumber(cl) then break end
		end
	end

	ossl.shutdown(ssl); ossl.free(ssl); ossl.free_context(ctx); sock:close()

	local full = table.concat(parts)
	local status_code = tonumber(full:match('^HTTP/%S+ (%d+)'))
	if not status_code then return nil, 'bad http response' end
	local he = full:find('\r\n\r\n', 1, true)
	return status_code, he and full:sub(he + 4) or ''
end

-- Route HTTP or HTTPS, returning (status_code, body) or (nil, err_msg)
local function do_request(method, url, body, extra_headers)
	if url:sub(1, 8) == 'https://' then
		return do_https_request(method, url, body, extra_headers)
	end
	local http = require('socket.http')
	local ltn12 = require('ltn12')
	local parts = {}
	local hdrs = {}
	if body and #body > 0 then
		hdrs['Content-Type'] = 'application/json'
		hdrs['Content-Length'] = tostring(#body)
	end
	if extra_headers then
		for k, v in pairs(extra_headers) do hdrs[k] = v end
	end
	local result, status = http.request({
		url = url,
		method = method,
		headers = hdrs,
		source = (body and #body > 0) and ltn12.source.string(body) or nil,
		sink = ltn12.sink.table(parts),
	})
	if result then
		return tonumber(status) or 0, table.concat(parts)
	else
		return nil, tostring(status)
	end
end

-- Retry transport-level failures only (do_request returned nil = no HTTP status
-- received, so the request almost certainly never completed server-side -> safe to
-- resend). A real HTTP status, even 5xx, means the server answered: do NOT retry.
-- Runs on the worker thread and blocks it, so the backoff window is bounded to keep
-- MQTT keepalive/pings from stalling. Logging goes over rx_channel (push_event 'log')
-- rather than print(), because worker-thread print() does not surface in the game log.
local HTTP_MAX_ATTEMPTS = 4
local HTTP_BACKOFF = { 0.3, 0.8, 1.5 }

local function request_with_retry(method, url, body, extra_headers)
	local status, resp
	for attempt = 1, HTTP_MAX_ATTEMPTS do
		status, resp = do_request(method, url, body, extra_headers)
		if status then
			if attempt > 1 then
				push_event('log', '[http-retry] ' .. method .. ' ' .. url .. ' succeeded on attempt ' .. attempt)
			end
			return status, resp
		end
		if attempt < HTTP_MAX_ATTEMPTS then
			local delay = HTTP_BACKOFF[attempt] or HTTP_BACKOFF[#HTTP_BACKOFF]
			push_event('log', '[http-retry] ' .. method .. ' ' .. url .. ' attempt ' .. attempt ..
				'/' .. HTTP_MAX_ATTEMPTS .. ' failed (' .. tostring(resp) .. '), retrying in ' .. delay .. 's')
			socket.sleep(delay)
		else
			push_event('log', '[http-retry] ' .. method .. ' ' .. url .. ' giving up after ' ..
				HTTP_MAX_ATTEMPTS .. ' attempts (' .. tostring(resp) .. ')')
		end
	end
	return status, resp
end

local function handle_http_post(url, body)
	local status, resp = request_with_retry('POST', url, body, nil)
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
end

local function handle_http_post_auth(url, body, token)
	local status, resp = request_with_retry('POST', url, body, { ['Authorization'] = 'Bearer ' .. token })
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
end

local function handle_http_put_auth(url, body, token)
	local status, resp = request_with_retry('PUT', url, body, { ['Authorization'] = 'Bearer ' .. token })
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
end

local function handle_http_get_auth(url, token)
	local status, resp = request_with_retry('GET', url, nil, { ['Authorization'] = 'Bearer ' .. token })
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
end

local function handle_http_delete_auth(url, token)
	local status, resp = request_with_retry('DELETE', url, nil, { ['Authorization'] = 'Bearer ' .. token })
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
end

local function handle_http_delete_with_body_auth(url, body, token)
	local status, resp = request_with_retry('DELETE', url, body, { ['Authorization'] = 'Bearer ' .. token })
	if status then push_event('http_response', tostring(status), resp)
	else push_event('http_error', tostring(resp)) end
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
	elseif action == 'http_put_auth' then
		handle_http_put_auth(parts[2], parts[3], parts[4])
	elseif action == 'http_get_auth' then
		handle_http_get_auth(parts[2], parts[3])
	elseif action == 'http_delete_auth' then
		handle_http_delete_auth(parts[2], parts[3])
	elseif action == 'http_delete_with_body_auth' then
		handle_http_delete_with_body_auth(parts[2], parts[3], parts[4])
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
