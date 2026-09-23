--[[
    Blocking byte streams (plain TCP or TLS) and a minimal HTTP/1.1 client
    for the Nakama I/O threads (networking/nakama_http_thread.lua,
    networking/websocket.lua). Runs only inside those love.threads - the
    main thread never touches a socket.

    TLS goes through networking/openssl_ffi.lua on top of a luasocket fd,
    the same technique mqtt_thread.lua's do_https_request uses (Balatro's
    Lua has no luasec). Like that function, certificates are not verified
    (verify = false) and DNS is IPv4-only via socket.dns.toip.
]]

local socket = require('socket')

local M = {}

local HANDSHAKE_RETRIES = 50
local HANDSHAKE_RETRY_DELAY = 0.1
local READ_CHUNK = 16384

----------------------------------------------------------------------
-- Streams
----------------------------------------------------------------------

local PlainStream = {}
PlainStream.__index = PlainStream

function PlainStream:send(data)
	local sent = 0
	while sent < #data do
		local last, err, partial = self.sock:send(data, sent + 1)
		if last then
			sent = last
		elseif partial and partial > sent then
			sent = partial
		elseif err ~= 'timeout' then
			return nil, err
		end
	end
	return true
end

-- Returns (data) when bytes arrived, ('') when timeout passed with none,
-- or (nil, err) once the peer closed or the read failed.
function PlainStream:receive(timeout)
	-- receive(n) waits for all n bytes, so wait on select and then take
	-- whatever is buffered with a zero timeout.
	local readable = socket.select({ self.sock }, nil, timeout)
	if not readable or #readable == 0 then
		return ''
	end
	self.sock:settimeout(0)
	local data, err, partial = self.sock:receive(READ_CHUNK)
	self.sock:settimeout(self.timeout)
	if data then
		return data
	end
	if partial and #partial > 0 then
		return partial
	end
	if err == 'timeout' then
		return ''
	end
	return nil, err
end

function PlainStream:close()
	if self.sock then
		self.sock:close()
		self.sock = nil
	end
end

local TlsStream = {}
TlsStream.__index = TlsStream

function TlsStream:send(data)
	local sent = 0
	while sent < #data do
		local written, err = self.ossl.write(self.ssl, data:sub(sent + 1))
		if written then
			sent = sent + written
		elseif err == 'wouldblock' then
			socket.select(nil, { self.sock }, 1)
		else
			return nil, err
		end
	end
	return true
end

function TlsStream:receive(timeout)
	-- Bytes OpenSSL already decrypted are invisible to socket.select.
	if self.ossl.pending(self.ssl) == 0 then
		local readable = socket.select({ self.sock }, nil, timeout)
		if not readable or #readable == 0 then
			return ''
		end
	end
	local data, err = self.ossl.read(self.ssl, READ_CHUNK)
	if data then
		return data
	end
	-- 'timeout' is WANT_READ: the socket was readable but a full TLS
	-- record hasn't arrived yet (see mqtt_thread.lua's do_https_request).
	if err == 'timeout' then
		return ''
	end
	return nil, err
end

function TlsStream:close()
	if self.ssl then
		self.ossl.shutdown(self.ssl)
		self.ossl.free(self.ssl)
		self.ssl = nil
	end
	if self.ctx then
		self.ossl.free_context(self.ctx)
		self.ctx = nil
	end
	if self.sock then
		self.sock:close()
		self.sock = nil
	end
	self.sni_ref = nil
end

local function wrap_tls(sock, host, timeout)
	local ok_load, ossl = pcall(require, 'openssl_ffi')
	if not ok_load or not ossl.available() then
		return nil, 'OpenSSL not available'
	end

	local fd = sock:getfd()
	if fd < 0 then
		return nil, 'no socket fd'
	end

	local ctx, ctx_err = ossl.new_context({ verify = false })
	if not ctx then
		return nil, 'ssl ctx: ' .. tostring(ctx_err)
	end

	-- sni_ref must stay reachable as long as ssl is in use (see
	-- openssl_ffi.lua's new_ssl), so the stream keeps it.
	local ssl, ssl_err, sni_ref = ossl.new_ssl(ctx, fd, host)
	if not ssl then
		ossl.free_context(ctx)
		return nil, 'ssl obj: ' .. tostring(ssl_err)
	end

	local stream = setmetatable({
		sock = sock,
		ossl = ossl,
		ctx = ctx,
		ssl = ssl,
		sni_ref = sni_ref,
		timeout = timeout,
	}, TlsStream)

	local ok, err = ossl.connect(ssl)
	for _ = 1, HANDSHAKE_RETRIES do
		if ok or err ~= 'wouldblock' then
			break
		end
		socket.sleep(HANDSHAKE_RETRY_DELAY)
		ok, err = ossl.connect(ssl)
	end
	if not ok then
		stream:close()
		return nil, 'tls: ' .. tostring(err)
	end
	return stream
end

-- Opens a stream to host:port, TLS when use_tls. timeout (seconds) bounds
-- the connect and every later blocking send.
function M.open(host, port, use_tls, timeout)
	local ip, dns_err = socket.dns.toip(host)
	if not ip then
		return nil, 'DNS: ' .. tostring(dns_err)
	end

	local sock = socket.tcp()
	sock:settimeout(timeout)
	local ok, err = sock:connect(ip, port)
	if not ok then
		sock:close()
		return nil, 'connect: ' .. tostring(err)
	end
	sock:setoption('tcp-nodelay', true)

	if not use_tls then
		return setmetatable({ sock = sock, timeout = timeout }, PlainStream)
	end
	local stream, tls_err = wrap_tls(sock, host, timeout)
	if not stream then
		sock:close()
		return nil, tls_err
	end
	return stream
end

----------------------------------------------------------------------
-- URLs
----------------------------------------------------------------------

local DEFAULT_PORTS = { http = 80, https = 443, ws = 80, wss = 443 }
local TLS_SCHEMES = { https = true, wss = true }

-- Returns { scheme, host, port, path, tls } or (nil, err). path keeps the
-- query string.
function M.parse_url(url)
	local scheme, authority, path = url:match('^(%a+)://([^/?#]+)(.*)$')
	if not scheme then
		return nil, 'invalid url: ' .. tostring(url)
	end
	scheme = scheme:lower()
	if not DEFAULT_PORTS[scheme] then
		return nil, 'unsupported scheme: ' .. scheme
	end
	local host, port = authority:match('^(.+):(%d+)$')
	host = host or authority
	port = tonumber(port) or DEFAULT_PORTS[scheme]
	if path == '' then
		path = '/'
	elseif path:sub(1, 1) == '?' then
		path = '/' .. path
	end
	return {
		scheme = scheme,
		host = host,
		port = port,
		path = path,
		tls = TLS_SCHEMES[scheme] or false,
	}
end

-- Host header value: the port is only included when it isn't the default.
function M.host_header(parsed)
	if parsed.port == DEFAULT_PORTS[parsed.scheme] then
		return parsed.host
	end
	return parsed.host .. ':' .. parsed.port
end

----------------------------------------------------------------------
-- HTTP/1.1
----------------------------------------------------------------------

-- Splits a raw response head into (status, headers) with lower-cased
-- header names, or nil if the status line is malformed.
function M.parse_response_head(head)
	local status = tonumber(head:match('^HTTP/%d%.%d (%d%d%d)'))
	if not status then
		return nil
	end
	local headers = {}
	for name, value in head:gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]*)') do
		headers[name:lower()] = value
	end
	return status, headers
end

-- Decodes a complete Transfer-Encoding: chunked body. Returns the body, or
-- nil when the terminating zero-length chunk hasn't arrived yet.
function M.dechunk(raw)
	local parts = {}
	local pos = 1
	while true do
		local line_end = raw:find('\r\n', pos, true)
		if not line_end then
			return nil
		end
		local size = tonumber(raw:sub(pos, line_end - 1):match('^%x+'), 16)
		if not size then
			return nil
		end
		if size == 0 then
			return table.concat(parts)
		end
		local data_start = line_end + 2
		if #raw < data_start + size + 1 then
			return nil
		end
		parts[#parts + 1] = raw:sub(data_start, data_start + size - 1)
		pos = data_start + size + 2
	end
end

-- Returns the body if everything the head promised has arrived, else nil.
local function complete_body(headers, raw, closed)
	if (headers['transfer-encoding'] or ''):lower():find('chunked', 1, true) then
		return M.dechunk(raw)
	end
	local length = tonumber(headers['content-length'])
	if length then
		if #raw >= length then
			return raw:sub(1, length)
		end
		return nil
	end
	return closed and raw or nil
end

-- One request, no retries. headers is a { name = value } table; body may
-- be nil. Returns (status, body) or (nil, err).
function M.request(method, url, headers, body, timeout)
	local parsed, url_err = M.parse_url(url)
	if not parsed then
		return nil, url_err
	end
	timeout = timeout or 10

	local stream, open_err = M.open(parsed.host, parsed.port, parsed.tls, timeout)
	if not stream then
		return nil, open_err
	end

	body = body or ''
	local lines = {
		method .. ' ' .. parsed.path .. ' HTTP/1.1',
		'Host: ' .. M.host_header(parsed),
		'Connection: close',
		'Content-Length: ' .. #body,
	}
	for name, value in pairs(headers or {}) do
		lines[#lines + 1] = name .. ': ' .. value
	end
	local ok, send_err = stream:send(table.concat(lines, '\r\n') .. '\r\n\r\n' .. body)
	if not ok then
		stream:close()
		return nil, 'send: ' .. tostring(send_err)
	end

	local buffer = ''
	local status, response_headers, body_start
	local deadline = socket.gettime() + timeout
	while true do
		local remaining = deadline - socket.gettime()
		if remaining <= 0 then
			stream:close()
			return nil, 'timeout'
		end
		local data, read_err = stream:receive(math.min(remaining, 0.5))
		local closed = data == nil
		if data then
			buffer = buffer .. data
		end

		if not status then
			local head_end = buffer:find('\r\n\r\n', 1, true)
			if head_end then
				status, response_headers = M.parse_response_head(buffer:sub(1, head_end - 1))
				if not status then
					stream:close()
					return nil, 'bad http response'
				end
				body_start = head_end + 4
			end
		end

		if status then
			local result = complete_body(response_headers, buffer:sub(body_start), closed)
			if result then
				stream:close()
				return status, result
			end
		end

		if closed then
			stream:close()
			return nil, 'connection closed: ' .. tostring(read_err)
		end
	end
end

return M
