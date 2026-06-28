--[[
    OpenSSL FFI Bindings for LuaJIT/Love2D
    Provides TLS support for MQTT connections in Balatro
    
    Compatible with OpenSSL 1.1.x and 3.x
]]

-- Logging helpers: use MPAPI when available, fall back to print()
local function ssl_log(msg)
	if MPAPI and MPAPI.sendDebugMessage then
		MPAPI.sendDebugMessage('[OpenSSL] ' .. msg)
	else
		print('[OpenSSL] ' .. msg)
	end
end

local function ssl_warn(msg)
	if MPAPI and MPAPI.sendWarnMessage then
		MPAPI.sendWarnMessage('[OpenSSL] ' .. msg)
	else
		print('[OpenSSL] WARNING: ' .. msg)
	end
end

local function ssl_error(msg)
	if MPAPI and MPAPI.sendWarnMessage then
		MPAPI.sendWarnMessage('[OpenSSL] ERROR: ' .. msg)
	else
		print('[OpenSSL] ERROR: ' .. msg)
	end
end

-- Check if FFI is available
local ffi_ok, ffi = pcall(require, 'ffi')
if not ffi_ok then
	ssl_warn('[OpenSSL] FFI not available')
	local stub = {
		available = function()
			return false
		end,
	}
	if MPAPI then
		MPAPI.networking.openssl_ffi = stub
	end
	return stub
end

local bit = require('bit')

-- OpenSSL C declarations
ffi.cdef([[
    // Basic types
    typedef struct ssl_st SSL;
    typedef struct ssl_ctx_st SSL_CTX;
    typedef struct ssl_method_st SSL_METHOD;

    // SSL methods
    const SSL_METHOD *TLS_client_method(void);
    const SSL_METHOD *TLS_method(void);
    
    // SSL_CTX functions
    SSL_CTX *SSL_CTX_new(const SSL_METHOD *method);
    void SSL_CTX_free(SSL_CTX *ctx);
    int SSL_CTX_set_default_verify_paths(SSL_CTX *ctx);
    void SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *callback);
    long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);
    int SSL_CTX_set_options(SSL_CTX *ctx, unsigned long options);
    
    // SSL functions
    SSL *SSL_new(SSL_CTX *ctx);
    void SSL_free(SSL *ssl);
    int SSL_set_fd(SSL *ssl, int fd);
    int SSL_connect(SSL *ssl);
    int SSL_read(SSL *ssl, void *buf, int num);
    int SSL_write(SSL *ssl, const void *buf, int num);
    int SSL_shutdown(SSL *ssl);
    int SSL_get_error(SSL *ssl, int ret);
    long SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg);
    int SSL_pending(SSL *ssl);
    
    // Error handling
    unsigned long ERR_get_error(void);
    char *ERR_error_string(unsigned long e, char *buf);
    void ERR_clear_error(void);
    
    // Init (OpenSSL 1.1.0+)
    int OPENSSL_init_ssl(uint64_t opts, void *settings);
]])

-- POSIX fcntl for non-blocking socket control
pcall(function()
	ffi.cdef([[
        int fcntl(int fd, int cmd, ...);
    ]])
end)

-- Constants
local SSL_VERIFY_NONE = 0
local SSL_VERIFY_PEER = 1
local SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
local SSL_CTRL_SET_MIN_PROTO_VERSION = 123
local SSL_ERROR_NONE = 0
local SSL_ERROR_WANT_READ = 2
local SSL_ERROR_WANT_WRITE = 3
local SSL_ERROR_ZERO_RETURN = 6
local OPENSSL_INIT_LOAD_SSL_STRINGS = 0x00200000
local OPENSSL_INIT_LOAD_CRYPTO_STRINGS = 0x00000002
local TLS1_2_VERSION = 0x0303
-- fcntl constants for non-blocking socket control
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = (ffi.os == 'OSX') and 0x0004 or 2048

-- SSL mode control
local SSL_MODE_AUTO_RETRY = 0x00000004
local SSL_CTRL_CLEAR_MODE = 78

local SSL_OP_NO_SSLv2 = 0x01000000
local SSL_OP_NO_SSLv3 = 0x02000000
local SSL_OP_NO_TLSv1 = 0x04000000
local SSL_OP_NO_TLSv1_1 = 0x10000000

-- Load OpenSSL libraries
local ssl_lib, crypto_lib
local openssl_loaded = false

local function load_openssl()
	if openssl_loaded then
		return true
	end

	local ok, err = pcall(function()
		-- Build list of names to try, per-platform. ffi.os is one of
		-- 'Windows', 'OSX', 'Linux', 'BSD', etc. The library *names* differ by
		-- OS (.dll / .dylib / .so) but every binding below is identical.
		local ssl_names, crypto_names
		if ffi.os == 'OSX' then
			-- macOS: we ship OpenSSL 3 as versioned .dylib files in the mod and
			-- load them by absolute path (see the search-dir block below). Apple's
			-- own /usr/lib/libssl.dylib is LibreSSL (deprecated, missing symbols),
			-- so we never load by bare name.
			ssl_names = { 'libssl.3.dylib' }
			crypto_names = { 'libcrypto.3.dylib' }
		elseif ffi.os == 'Windows' then
			ssl_names = {
				'libssl.dll',
				'libssl-3-x64.dll',
				'libssl-3.dll',
				'libssl-1_1-x64.dll',
				'libssl-1_1.dll',
				'ssl.dll',
				'ssl-3-x64.dll',
				'ssl-3.dll',
				'libssl-3-x64',
				'libssl-3',
				'libssl',
				'libssl-1_1-x64',
				'libssl-1_1',
				'ssl-3-x64',
				'ssl-3',
				'ssl',
			}
			crypto_names = {
				'libcrypto.dll',
				'libcrypto-3-x64.dll',
				'libcrypto-3.dll',
				'libcrypto-1_1-x64.dll',
				'libcrypto-1_1.dll',
				'crypto.dll',
				'crypto-3-x64.dll',
				'crypto-3.dll',
				'libcrypto-3-x64',
				'libcrypto-3',
				'libcrypto',
				'libcrypto-1_1-x64',
				'libcrypto-1_1',
				'crypto-3-x64',
				'crypto-3',
				'crypto',
			}
		else
			-- Linux / BSD: shared objects with .so soname suffixes.
			ssl_names = {
				'libssl.so',
				'libssl.so.3',
				'libssl.so.1.1',
				'ssl',
			}
			crypto_names = {
				'libcrypto.so',
				'libcrypto.so.3',
				'libcrypto.so.1.1',
				'crypto',
			}
		end

		-- Discover base paths to search for the libraries.
		local search_dirs = {}

		if ffi.os == 'OSX' then
			-- We ship libssl.3.dylib + libcrypto.3.dylib in the mod's networking/
			-- folder and load them by ABSOLUTE path. A bare name is not an option
			-- on macOS: it resolves to Apple's /usr/lib LibreSSL and aborts the
			-- process with "loading libcrypto in an unsafe way" (Abort trap: 6).
			--
			-- We can't read the mod path from MPAPI here (the MQTT worker runs in
			-- its own Lua state with no MPAPI), but we don't need to: core.lua
			-- adds "<mod>/networking/?.lua" to package.path, and that string is
			-- forwarded to the worker's setup, so the absolute networking/ dir is
			-- already available wherever this runs. Pull it back out of there.
			local dir
			for entry in (package.path or ''):gmatch('[^;]+') do
				dir = entry:match('^(.-[/\\]networking[/\\])%?')
				if dir then
					break
				end
			end
			-- Fallback to MPAPI.path on the main thread if the entry isn't present.
			if not dir and MPAPI and MPAPI.path then
				dir = (MPAPI.path:gsub('/*$', '')) .. '/networking/'
			end
			if dir then
				search_dirs[#search_dirs + 1] = dir
			end
		elseif ffi.os == 'Windows' then
			search_dirs[#search_dirs + 1] = '' -- default DLL search path
		else
			-- Linux/BSD: the system OpenSSL is real OpenSSL (not LibreSSL), so the
			-- default search path and standard lib dirs are safe to use.
			search_dirs[#search_dirs + 1] = '' -- default ffi.load search path
			local nix_dirs = {
				'/usr/lib/',
				'/usr/lib/x86_64-linux-gnu/',
				'/usr/lib64/',
				'/usr/local/lib/',
				'/lib/',
			}
			for _, d in ipairs(nix_dirs) do
				search_dirs[#search_dirs + 1] = d
			end
		end

		-- Search game-relative locations discovered via love.filesystem. This is
		-- really for Windows, where OpenSSL DLLs are dropped next to the game and
		-- getSource() returns that folder. On Linux it's just a harmless extra
		-- fallback (the real libs come from the system path / nix_dirs above).
		-- macOS is skipped entirely: its libs are bundled in the mod folder
		-- (found via package.path above), so getSource()/save/'./' only point at
		-- the wrong places here -- and a bare './name' could even reach the
		-- system LibreSSL and abort the process.
		if ffi.os ~= 'OSX' then
			-- love.filesystem.getSource() may return the exe path (e.g.
			-- "Z:\...\Balatro\Balatro.exe"); strip the filename to get the dir.
			if love and love.filesystem then
				local src = love.filesystem.getSource()
				if src then
					-- Strip trailing filename if it looks like an exe/file
					local dir = src:match('^(.+)[/\\][^/\\]+%.[^/\\]+$') or src
					search_dirs[#search_dirs + 1] = dir .. '/'
					-- Also try with backslash (Wine paths)
					search_dirs[#search_dirs + 1] = dir .. '\\'
				end
				local save = love.filesystem.getSaveDirectory()
				if save then
					search_dirs[#search_dirs + 1] = save .. '/'
				end
			end

			-- Also try CWD-relative
			search_dirs[#search_dirs + 1] = './'
		end

		-- Try every (dir, name) combination; return the first lib that loads.
		local function try_load(names, label)
			for _, dir in ipairs(search_dirs) do
				for _, name in ipairs(names) do
					local path = dir .. name
					local ok2, lib = pcall(ffi.load, path)
					if ok2 then
						ssl_log('Loaded ' .. label .. ' library: ' .. path)
						return lib
					end
					ssl_log('  tried ' .. label .. ': ' .. path .. ' -> ' .. tostring(lib))
				end
			end
		end

		-- crypto first: libssl depends on libcrypto already being loaded.
		crypto_lib = try_load(crypto_names, 'crypto')
		if not crypto_lib then
			ssl_warn('Could not load crypto library (ssl may still work if system-provided)')
		end

		ssl_lib = try_load(ssl_names, 'ssl')
		if not ssl_lib then
			error('Could not load OpenSSL SSL library')
		end
	end)

	if not ok then
		ssl_error('Failed to load: ' .. tostring(err))
		return false, err
	end

	-- Initialize OpenSSL
	pcall(function()
		ssl_lib.OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS + OPENSSL_INIT_LOAD_CRYPTO_STRINGS, nil)
	end)

	openssl_loaded = true
	return true
end

-- Module table
local M = {}

function M.get_error()
	if not crypto_lib then
		return 'OpenSSL not loaded'
	end
	local err = crypto_lib.ERR_get_error()
	if err == 0 then
		return nil
	end
	local buf = ffi.new('char[256]')
	crypto_lib.ERR_error_string(err, buf)
	return ffi.string(buf)
end

function M.clear_errors()
	if crypto_lib then
		crypto_lib.ERR_clear_error()
	end
end

function M.new_context(opts)
	opts = opts or {}

	local ok, err = load_openssl()
	if not ok then
		return nil, 'Failed to load OpenSSL: ' .. tostring(err)
	end

	local method = ssl_lib.TLS_client_method()
	if method == nil then
		return nil, 'Failed to get TLS method'
	end

	local ctx = ssl_lib.SSL_CTX_new(method)
	if ctx == nil then
		return nil, 'Failed to create SSL context: ' .. (M.get_error() or 'unknown error')
	end

	pcall(function()
		ssl_lib.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)
	end)

	pcall(function()
		ssl_lib.SSL_CTX_set_options(ctx, SSL_OP_NO_SSLv2 + SSL_OP_NO_SSLv3 + SSL_OP_NO_TLSv1 + SSL_OP_NO_TLSv1_1)
	end)

	if opts.verify == false then
		ssl_lib.SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)
	else
		ssl_lib.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
		ssl_lib.SSL_CTX_set_default_verify_paths(ctx)
	end

	return ctx
end

function M.free_context(ctx)
	if ctx ~= nil and ssl_lib then
		ssl_lib.SSL_CTX_free(ctx)
	end
end

function M.new_ssl(ctx, fd, hostname)
	if not ssl_lib then
		return nil, 'OpenSSL not loaded'
	end

	local ssl = ssl_lib.SSL_new(ctx)
	if ssl == nil then
		return nil, 'Failed to create SSL object: ' .. (M.get_error() or 'unknown error')
	end

	if ssl_lib.SSL_set_fd(ssl, fd) ~= 1 then
		ssl_lib.SSL_free(ssl)
		return nil, 'Failed to set SSL fd: ' .. (M.get_error() or 'unknown error')
	end

	if hostname then
		local hostname_cstr = ffi.new('char[?]', #hostname + 1, hostname)
		ssl_lib.SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, hostname_cstr)
	end

	return ssl
end

function M.connect(ssl)
	if not ssl_lib then
		return false, 'OpenSSL not loaded'
	end

	M.clear_errors()
	local ret = ssl_lib.SSL_connect(ssl)
	if ret == 1 then
		return true
	end

	local err_code = ssl_lib.SSL_get_error(ssl, ret)
	if err_code == SSL_ERROR_WANT_READ or err_code == SSL_ERROR_WANT_WRITE then
		return nil, 'wouldblock'
	end

	return false, 'SSL connect failed: ' .. (M.get_error() or 'error code ' .. err_code)
end

function M.write(ssl, data)
	if not ssl_lib then
		return nil, 'OpenSSL not loaded'
	end

	M.clear_errors()
	local ret = ssl_lib.SSL_write(ssl, data, #data)
	if ret > 0 then
		return ret
	end

	local err_code = ssl_lib.SSL_get_error(ssl, ret)
	if err_code == SSL_ERROR_WANT_READ or err_code == SSL_ERROR_WANT_WRITE then
		return nil, 'wouldblock'
	end

	return nil, 'SSL write failed: ' .. (M.get_error() or 'error code ' .. err_code)
end

function M.read(ssl, size)
	if not ssl_lib then
		return nil, 'OpenSSL not loaded'
	end

	size = size or 4096
	local buf = ffi.new('char[?]', size)

	M.clear_errors()
	local ret = ssl_lib.SSL_read(ssl, buf, size)
	if ret > 0 then
		return ffi.string(buf, ret)
	end

	local err_code = ssl_lib.SSL_get_error(ssl, ret)
	if err_code == SSL_ERROR_WANT_READ or err_code == SSL_ERROR_WANT_WRITE then
		return nil, 'timeout'
	elseif err_code == SSL_ERROR_ZERO_RETURN then
		return nil, 'closed'
	end

	return nil, 'SSL read failed: ' .. (M.get_error() or 'error code ' .. err_code)
end

function M.pending(ssl)
	if not ssl_lib then
		return 0
	end
	return ssl_lib.SSL_pending(ssl)
end

function M.shutdown(ssl)
	if ssl ~= nil and ssl_lib then
		ssl_lib.SSL_shutdown(ssl)
	end
end

function M.free(ssl)
	if ssl ~= nil and ssl_lib then
		ssl_lib.SSL_free(ssl)
	end
end

-- Set a file descriptor to non-blocking mode via fcntl
function M.set_nonblocking(fd)
	local ok, err = pcall(function()
		local flags = ffi.C.fcntl(fd, F_GETFL)
		if flags < 0 then
			error('fcntl F_GETFL failed')
		end
		local ret = ffi.C.fcntl(fd, F_SETFL, ffi.cast('int', bit.bor(flags, O_NONBLOCK)))
		if ret < 0 then
			error('fcntl F_SETFL failed')
		end
	end)
	if not ok then
		return nil, tostring(err)
	end
	return true
end

-- Disable SSL_MODE_AUTO_RETRY so SSL_read returns WANT_READ immediately
-- instead of retrying internally on non-application records
function M.disable_auto_retry(ssl)
	if not ssl_lib then
		return nil, 'OpenSSL not loaded'
	end
	ssl_lib.SSL_ctrl(ssl, SSL_CTRL_CLEAR_MODE, SSL_MODE_AUTO_RETRY, nil)
	return true
end

function M.available()
	local ok = load_openssl()
	return ok
end

if MPAPI then
	MPAPI.networking.openssl_ffi = M
end
return M
