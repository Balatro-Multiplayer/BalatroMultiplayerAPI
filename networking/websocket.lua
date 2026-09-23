--[[
    Minimal RFC 6455 WebSocket client for the Nakama socket thread
    (networking/nakama_ws_thread.lua). ws:// runs over plain TCP, wss://
    over TLS, both via networking/nakama_net.lua.

    Supports what Nakama's realtime socket uses: text/binary messages,
    fragmented (continuation) messages, ping -> pong, and the close
    handshake. No extensions (permessage-deflate) or subprotocols.

    The framing, SHA-1 and handshake helpers are pure functions so they can
    be tested on the main thread without a network.
]]

local bit = require('bit')

local band, bor, bxor, lshift, rshift, rol, tobit = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.rol, bit.tobit
local byte, char, concat = string.byte, string.char, table.concat

local M = {}

M.OP_CONTINUATION = 0x0
M.OP_TEXT = 0x1
M.OP_BINARY = 0x2
M.OP_CLOSE = 0x8
M.OP_PING = 0x9
M.OP_PONG = 0xA

local ACCEPT_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
local CLOSE_WAIT_SECONDS = 1

----------------------------------------------------------------------
-- SHA-1 and base64 (only used for the Sec-WebSocket-Accept check)
----------------------------------------------------------------------

local function u32_be(n)
	return char(band(rshift(n, 24), 0xFF), band(rshift(n, 16), 0xFF), band(rshift(n, 8), 0xFF), band(n, 0xFF))
end

-- Returns the raw 20-byte SHA-1 digest of msg.
function M.sha1(msg)
	local h0, h1, h2, h3, h4 =
		tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE), tobit(0x10325476), tobit(0xC3D2E1F0)

	local bit_len = #msg * 8
	msg = msg
		.. '\128'
		.. string.rep('\0', (55 - #msg) % 64)
		.. u32_be(math.floor(bit_len / 2 ^ 32))
		.. u32_be(bit_len % 2 ^ 32)

	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			local a, b, c, d = byte(msg, chunk + i * 4, chunk + i * 4 + 3)
			w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
		end
		for i = 16, 79 do
			w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = bor(band(b, c), band(bit.bnot(b), d)), 0x5A827999
			elseif i < 40 then
				f, k = bxor(b, c, d), 0x6ED9EBA1
			elseif i < 60 then
				f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
			else
				f, k = bxor(b, c, d), 0xCA62C1D6
			end
			local temp = tobit(rol(a, 5) + f + e + k + w[i])
			e, d, c, b, a = d, c, rol(b, 30), a, temp
		end

		h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
	end

	return u32_be(h0) .. u32_be(h1) .. u32_be(h2) .. u32_be(h3) .. u32_be(h4)
end

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function M.base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = byte(data, i, i + 2)
		local n = lshift(a, 16) + lshift(b or 0, 8) + (c or 0)
		local s1, s2, s3, s4 =
			rshift(n, 18) + 1, band(rshift(n, 12), 63) + 1, band(rshift(n, 6), 63) + 1, band(n, 63) + 1
		out[#out + 1] = B64:sub(s1, s1)
			.. B64:sub(s2, s2)
			.. (b and B64:sub(s3, s3) or '=')
			.. (c and B64:sub(s4, s4) or '=')
	end
	return concat(out)
end

function M.accept_key(key)
	return M.base64(M.sha1(key .. ACCEPT_GUID))
end

----------------------------------------------------------------------
-- Framing
----------------------------------------------------------------------

local function apply_mask(payload, mask_key)
	local m = { byte(mask_key, 1, 4) }
	local out = {}
	local CHUNK = 4096
	for start = 1, #payload, CHUNK do
		local bytes = { byte(payload, start, math.min(start + CHUNK - 1, #payload)) }
		for i = 1, #bytes do
			bytes[i] = bxor(bytes[i], m[(start + i - 2) % 4 + 1])
		end
		out[#out + 1] = char(unpack(bytes))
	end
	return concat(out)
end

-- Builds one frame. mask_key is 4 bytes for client -> server frames (RFC
-- 6455 5.3 requires clients to mask), nil for an unmasked frame. fin
-- defaults to true.
function M.encode_frame(opcode, payload, mask_key, fin)
	payload = payload or ''
	local len = #payload
	local head = char(bor(fin == false and 0 or 0x80, opcode))
	local mask_bit = mask_key and 0x80 or 0

	if len < 126 then
		head = head .. char(bor(mask_bit, len))
	elseif len < 0x10000 then
		head = head .. char(bor(mask_bit, 126), rshift(len, 8), band(len, 0xFF))
	else
		head = head .. char(bor(mask_bit, 127)) .. u32_be(math.floor(len / 2 ^ 32)) .. u32_be(len % 2 ^ 32)
	end

	if mask_key then
		return head .. mask_key .. apply_mask(payload, mask_key)
	end
	return head .. payload
end

-- Parses one frame from the start of buf. Returns (frame, bytes_used), or
-- nil when buf doesn't hold a whole frame yet. frame is { fin, opcode,
-- payload } with the payload already unmasked.
function M.decode_frame(buf)
	if #buf < 2 then
		return nil
	end
	local b1, b2 = byte(buf, 1, 2)
	local masked = band(b2, 0x80) ~= 0
	local len = band(b2, 0x7F)
	local pos = 3

	if len == 126 then
		if #buf < 4 then
			return nil
		end
		local x, y = byte(buf, 3, 4)
		len = x * 256 + y
		pos = 5
	elseif len == 127 then
		if #buf < 10 then
			return nil
		end
		len = 0
		for i = 3, 10 do
			len = len * 256 + byte(buf, i)
		end
		pos = 11
	end

	local mask_key
	if masked then
		if #buf < pos + 3 then
			return nil
		end
		mask_key = buf:sub(pos, pos + 3)
		pos = pos + 4
	end

	if #buf < pos + len - 1 then
		return nil
	end
	local payload = buf:sub(pos, pos + len - 1)
	if mask_key then
		payload = apply_mask(payload, mask_key)
	end

	return {
		fin = band(b1, 0x80) ~= 0,
		opcode = band(b1, 0x0F),
		payload = payload,
	}, pos + len - 1
end

----------------------------------------------------------------------
-- Handshake
----------------------------------------------------------------------

function M.build_handshake(host_header, path, key)
	return concat({
		'GET ' .. path .. ' HTTP/1.1',
		'Host: ' .. host_header,
		'Upgrade: websocket',
		'Connection: Upgrade',
		'Sec-WebSocket-Key: ' .. key,
		'Sec-WebSocket-Version: 13',
		'',
		'',
	}, '\r\n')
end

-- Checks the server's handshake response head (everything before the
-- blank line) against the key the client sent. Returns true or (nil, err).
function M.check_handshake(head, key)
	local net = require('nakama_net')
	local status, headers = net.parse_response_head(head)
	if status ~= 101 then
		return nil, 'handshake rejected: ' .. (head:match('^[^\r\n]*') or '')
	end
	if (headers['upgrade'] or ''):lower() ~= 'websocket' then
		return nil, 'handshake missing Upgrade: websocket'
	end
	if headers['sec-websocket-accept'] ~= M.accept_key(key) then
		return nil, 'handshake Sec-WebSocket-Accept mismatch'
	end
	return true
end

----------------------------------------------------------------------
-- Connection
----------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

local function random_bytes(n)
	local ok, ossl = pcall(require, 'openssl_ffi')
	if ok and ossl.available() then
		local bytes = ossl.random_bytes(n)
		if bytes then
			return bytes
		end
	end
	local t = {}
	for i = 1, n do
		t[i] = math.random(0, 255)
	end
	return char(unpack(t))
end

-- Opens a WebSocket to url (ws:// or wss://). timeout (seconds) bounds
-- the TCP/TLS connect and the upgrade handshake. Returns a Connection or
-- (nil, err).
function M.connect(url, timeout)
	local net = require('nakama_net')
	local socket = require('socket')
	timeout = timeout or 10

	local parsed, url_err = net.parse_url(url)
	if not parsed then
		return nil, url_err
	end
	if parsed.scheme ~= 'ws' and parsed.scheme ~= 'wss' then
		return nil, 'not a websocket url: ' .. url
	end

	local stream, open_err = net.open(parsed.host, parsed.port, parsed.tls, timeout)
	if not stream then
		return nil, open_err
	end

	local key = M.base64(random_bytes(16))
	local ok, send_err = stream:send(M.build_handshake(net.host_header(parsed), parsed.path, key))
	if not ok then
		stream:close()
		return nil, 'send: ' .. tostring(send_err)
	end

	local buffer = ''
	local deadline = socket.gettime() + timeout
	while not buffer:find('\r\n\r\n', 1, true) do
		local remaining = deadline - socket.gettime()
		if remaining <= 0 then
			stream:close()
			return nil, 'handshake timeout'
		end
		local data, read_err = stream:receive(math.min(remaining, 0.5))
		if not data then
			stream:close()
			return nil, 'handshake: ' .. tostring(read_err)
		end
		buffer = buffer .. data
	end

	local head_end = buffer:find('\r\n\r\n', 1, true)
	local accepted, handshake_err = M.check_handshake(buffer:sub(1, head_end - 1), key)
	if not accepted then
		stream:close()
		return nil, handshake_err
	end

	return setmetatable({
		stream = stream,
		-- Frames can follow the handshake in the same read.
		buffer = buffer:sub(head_end + 4),
		fragments = nil,
		fragment_opcode = nil,
		closed = false,
	}, Connection)
end

function Connection:send_frame(opcode, payload)
	if self.closed then
		return nil, 'closed'
	end
	return self.stream:send(M.encode_frame(opcode, payload, random_bytes(4)))
end

function Connection:send_text(text)
	return self:send_frame(M.OP_TEXT, text)
end

-- Handles one complete frame. Returns an event table or nil.
function Connection:handle_frame(frame)
	local op = frame.opcode
	if op == M.OP_PING then
		self:send_frame(M.OP_PONG, frame.payload)
		return nil
	elseif op == M.OP_PONG then
		return nil
	elseif op == M.OP_CLOSE then
		if not self.closed then
			-- Echo the close, then the server drops the TCP connection.
			self:send_frame(M.OP_CLOSE, frame.payload:sub(1, 2))
			self.closed = true
		end
		local code = #frame.payload >= 2 and (byte(frame.payload, 1) * 256 + byte(frame.payload, 2)) or nil
		return { type = 'closed', code = code, reason = frame.payload:sub(3) }
	end

	-- Data frames: a message is one fin frame, or a text/binary frame
	-- followed by continuation frames ending in a fin one.
	if op ~= M.OP_CONTINUATION then
		self.fragments = { frame.payload }
		self.fragment_opcode = op
	elseif self.fragments then
		self.fragments[#self.fragments + 1] = frame.payload
	else
		return nil
	end
	if not frame.fin then
		return nil
	end
	local data = concat(self.fragments)
	self.fragments = nil
	return { type = 'message', data = data, binary = self.fragment_opcode == M.OP_BINARY }
end

-- Waits up to timeout seconds for data and returns every event it
-- completed: { type = 'message', data, binary } or { type = 'closed',
-- code, reason }. A dropped connection is reported as 'closed' too.
function Connection:poll(timeout)
	local events = {}
	local data, err = self.stream:receive(timeout)
	if data then
		self.buffer = self.buffer .. data
	end

	while true do
		local frame, used = M.decode_frame(self.buffer)
		if not frame then
			break
		end
		self.buffer = self.buffer:sub(used + 1)
		local event = self:handle_frame(frame)
		if event then
			events[#events + 1] = event
			if event.type == 'closed' then
				return events
			end
		end
	end

	if not data then
		self.closed = true
		events[#events + 1] = { type = 'closed', reason = tostring(err) }
	end
	return events
end

-- Starts the close handshake and waits briefly for the server's echo.
function Connection:close()
	if not self.closed then
		self:send_frame(M.OP_CLOSE, char(0x03, 0xE8)) -- 1000 normal closure
		self.closed = true
		local socket = require('socket')
		local deadline = socket.gettime() + CLOSE_WAIT_SECONDS
		while socket.gettime() < deadline do
			local data = self.stream:receive(0.1)
			if not data then
				break
			end
			self.buffer = self.buffer .. data
			local frame = M.decode_frame(self.buffer)
			if frame and frame.opcode == M.OP_CLOSE then
				break
			end
		end
	end
	self.stream:close()
end

return M
