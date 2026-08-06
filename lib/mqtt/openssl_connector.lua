--[[
    OpenSSL Connector for luamqtt

    Drop-in replacement for luasocket_ssl that uses FFI OpenSSL bindings
    instead of luasec. Designed for Balatro's restricted Lua environment.
]]

local openssl_connector = {}

local socket = require('socket')
local openssl = require('openssl_ffi')

-- Handshake retry parameters
local HANDSHAKE_MAX_RETRIES = 50
local HANDSHAKE_RETRY_DELAY = 0.1

-- Wrapper object that mimics luasocket's interface but uses OpenSSL
local SSLSocket = {}
SSLSocket.__index = SSLSocket

function SSLSocket:send(data, i, j)
	local start_pos = i or 1
	local end_pos = j or #data
	local slice = data:sub(start_pos, end_pos)

	local written, err = openssl.write(self.ssl, slice)
	if written then
		-- Return byte index (luasocket contract), not byte count
		return start_pos + written - 1
	end

	if err == 'wouldblock' or err == 'timeout' then
		-- Wait for socket to become writable, then retry once
		local _, writable = socket.select(nil, { self.sock }, 1)
		if writable and #writable > 0 then
			written, err = openssl.write(self.ssl, slice)
			if written then
				return start_pos + written - 1
			end
		end
		return nil, err or 'timeout'
	end

	return nil, err
end

function SSLSocket:receive(size)
	-- Accumulation buffer: SSL_read may return fewer bytes than requested
	-- (one TLS record at a time), but luamqtt expects exactly size bytes.
	self._recv_buf = self._recv_buf or ''

	-- Return buffered data if we already have enough
	if #self._recv_buf >= size then
		local result = self._recv_buf:sub(1, size)
		self._recv_buf = self._recv_buf:sub(size + 1)
		return result
	end

	-- Determine effective timeout:
	--   nil = blocking (infinite) -- luamqtt sync path
	--   0   = non-blocking        -- game loop / ioloop path
	--   >0  = blocking with deadline
	local timeout = self.timeout
	local deadline = nil
	if timeout and timeout > 0 then
		deadline = socket.gettime() + timeout
	end

	while true do
		local needed = size - #self._recv_buf

		-- Step 1: Check OpenSSL internal buffer (invisible to socket.select)
		local pending = openssl.pending(self.ssl)
		if pending > 0 then
			local data, err = openssl.read(self.ssl, needed)
			if data then
				self._recv_buf = self._recv_buf .. data
				if #self._recv_buf >= size then
					local result = self._recv_buf:sub(1, size)
					self._recv_buf = self._recv_buf:sub(size + 1)
					return result
				end
			elseif err ~= 'timeout' and err ~= 'wouldblock' then
				return nil, err
			end
		end

		-- Step 2: Wait for kernel socket readability
		local select_timeout
		if timeout == nil then
			-- Blocking mode: poll with short interval so we re-check
			-- SSL_pending on each iteration (OpenSSL may buffer data
			-- that socket.select cannot see)
			select_timeout = 0.1
		elseif timeout == 0 then
			select_timeout = 0
		else
			local remaining = deadline - socket.gettime()
			if remaining <= 0 then
				return nil, 'timeout'
			end
			select_timeout = remaining
		end

		local readable = socket.select({ self.sock }, nil, select_timeout)

		if readable and #readable > 0 then
			-- Step 3: Socket has data -- call SSL_read.  Because we set
			-- O_NONBLOCK via fcntl and disabled AUTO_RETRY, this will
			-- NOT block: it returns data, WANT_READ, or an error.
			local data, err = openssl.read(self.ssl, needed)
			if data then
				self._recv_buf = self._recv_buf .. data
				if #self._recv_buf >= size then
					local result = self._recv_buf:sub(1, size)
					self._recv_buf = self._recv_buf:sub(size + 1)
					return result
				end
				-- Partial read -- loop to get more
			elseif err == 'timeout' or err == 'wouldblock' then
				-- WANT_READ: partial TLS record, loop to wait for more
			else
				return nil, err
			end
		else
			-- select timed out
			if timeout == 0 then
				return nil, 'timeout'
			end
			if deadline and socket.gettime() >= deadline then
				return nil, 'timeout'
			end
			-- Blocking mode (nil timeout): continue polling
		end
	end
end

function SSLSocket:settimeout(timeout)
	self.timeout = timeout
end

function SSLSocket:close()
	if self.ssl then
		openssl.shutdown(self.ssl)
		openssl.free(self.ssl)
		self.ssl = nil
		self.sni_ref = nil
	end
	if self.sock then
		pcall(function()
			self.sock:close()
		end)
		self.sock = nil
	end
end

function SSLSocket:shutdown()
	self:close()
end

function SSLSocket:getfd()
	if self.sock then
		return self.sock:getfd()
	end
	return -1
end

-- Open network connection with TLS
function openssl_connector.connect(conn)
	-- Create SSL context if not already done
	if not conn.ssl_ctx then
		local verify = true
		if conn.secure_params then
			if conn.secure_params.verify == 'none' or conn.secure_params.verify == false then
				verify = false
			end
		end

		local ctx, err = openssl.new_context({ verify = verify })
		if not ctx then
			return false, 'Failed to create SSL context: ' .. tostring(err)
		end
		conn.ssl_ctx = ctx
	end

	-- Open regular TCP connection
	local sock, err = socket.connect(conn.host, conn.port)
	if not sock then
		return false, 'socket.connect failed: ' .. tostring(err)
	end

	-- Keep socket in blocking mode for handshake
	sock:settimeout(30)

	-- Get file descriptor
	local fd = sock:getfd()
	if fd < 0 then
		sock:shutdown()
		return false, 'Failed to get socket fd'
	end

	-- Create SSL object. sni_ref is the FFI buffer OpenSSL's SNI extension
	-- points at internally (no copy on OpenSSL's side -- see new_ssl's own
	-- comment) and must stay alive for as long as `ssl` does; it gets stored
	-- on `wrapper` below for exactly that reason. Letting it go out of scope
	-- here would leave `ssl` holding a pointer straight into GC'd memory.
	local ssl, err, sni_ref = openssl.new_ssl(conn.ssl_ctx, fd, conn.host)
	if not ssl then
		sock:shutdown()
		return false, 'Failed to create SSL: ' .. tostring(err)
	end

	-- Perform handshake
	local ok, handshake_err = openssl.connect(ssl)
	if not ok then
		-- Retry a few times for wouldblock
		if handshake_err == 'wouldblock' then
			for i = 1, HANDSHAKE_MAX_RETRIES do
				socket.sleep(HANDSHAKE_RETRY_DELAY)
				ok, handshake_err = openssl.connect(ssl)
				if ok then
					break
				end
				if handshake_err ~= 'wouldblock' then
					break
				end
			end
		end
	end

	if not ok then
		openssl.free(ssl)
		sock:shutdown()
		return false, 'TLS handshake failed: ' .. tostring(handshake_err or 'timeout')
	end

	-- Set the underlying fd to TRUE non-blocking (fcntl on POSIX, ioctlsocket
	-- on Windows -- see set_nonblocking's own comment). luasocket's
	-- settimeout(0) only sets internal Lua-level timeouts, it does NOT set
	-- O_NONBLOCK on the fd.
	-- nb_err intentionally unchecked past this point (matches this file's
	-- existing silent-degrade convention -- e.g. crypto_lib load failures
	-- above); disable_auto_retry below no longer depends on this succeeding.
	local nb_ok, nb_err = openssl.set_nonblocking(fd)

	-- Disable SSL_MODE_AUTO_RETRY (enabled by default in OpenSSL 1.1.1+)
	-- unconditionally, not just when set_nonblocking above succeeded: with
	-- AUTO_RETRY, SSL_read retries internally on non-application records
	-- (TLS 1.3 post-handshake NewSessionTicket messages chief among them --
	-- servers routinely send these right after the handshake, before any
	-- application data) which can block the calling thread regardless of the
	-- fd's blocking mode, defeating the whole point of the 0.05s poll-and-
	-- return pattern _sync_iteration relies on.
	openssl.disable_auto_retry(ssl)
	-- Also set luasocket's internal timeout for consistency
	sock:settimeout(0)

	-- Create wrapper object. Holding sni_ref here (never read again, just
	-- kept reachable) anchors the SNI buffer against GC for exactly as long
	-- as `ssl` itself is alive.
	local wrapper = setmetatable({
		sock = sock,
		ssl = ssl,
		sni_ref = sni_ref,
		timeout = 0,
		_recv_buf = '',
	}, SSLSocket)

	conn.sock = wrapper
	return true
end

-- Shutdown network connection
function openssl_connector.shutdown(conn)
	if conn.sock then
		conn.sock:close()
		conn.sock = nil
	end
	if conn.ssl_ctx then
		openssl.free_context(conn.ssl_ctx)
		conn.ssl_ctx = nil
	end
end

-- Send data
function openssl_connector.send(conn, data, i, j)
	if not conn.sock then
		return nil, 'not connected'
	end
	return conn.sock:send(data, i, j)
end

-- Receive data
function openssl_connector.receive(conn, size)
	if not conn.sock then
		return nil, 'not connected'
	end
	return conn.sock:receive(size)
end

-- Set timeout
function openssl_connector.settimeout(conn, timeout)
	conn.timeout = timeout
	if conn.sock then
		conn.sock:settimeout(timeout)
	end
end

return openssl_connector
