--[[
    Ranked-mode launcher<->mod supervision channel - network thread.
    Receives commands on tx_channel, sends events on rx_channel, exactly
    like networking/mqtt_thread.lua's own convention - but unlike that
    file, messages here are Lua *tables*, not SEP-joined strings: this
    channel's payloads (nonces, AES-GCM ciphertext) are arbitrary binary
    data that could contain the SEP byte itself, which a string-join
    protocol can't safely carry. Love2D's thread Channels support pushing
    tables directly, so there's no need for a delimiter at all.

    Protocol (mirrors Source/Launcher/src/anticheat/rankedsupervisor.cpp
    exactly - see that file's class comment for the full step-by-step and
    the threat-model reasoning):
      1. Connect to 127.0.0.1:<port>, send our 32-byte random nonce
         immediately, read the launcher's 32-byte nonce.
      2. HKDF-SHA256(secret, salt=modNonce||launcherNonce, info) derives
         two directional AES-256 keys (anticheat/crypto.lua).
      3. Every message after that is [4-byte BE length][AES-256-GCM
         ciphertext+16-byte tag], nonce = a 12-byte big-endian per-
         direction counter starting at 0.
      4. Send our hello frame right away; separately, successfully
         decrypting the launcher's hello frame is this side's independent
         proof the launcher knows the secret (each direction's key is
         derived from the same shared secret, so decrypt success is only
         possible for someone who knew it - no extra round trip needed).
      5. After that, both sides send {"type":"heartbeat","ts":<unix_ms>}
         every 5s; any valid decrypted frame resets the peer's "last
         seen" clock.
]]

local tx_channel, rx_channel = ... -- passed from main thread

-- Read setup message: {port, secret_hex, pkg_path, pkg_cpath}
local setup = tx_channel:demand() -- blocks until available
if setup.pkg_path then
	package.path = setup.pkg_path
end
if setup.pkg_cpath then
	package.cpath = setup.pkg_cpath
end

local socket = require('socket')
require('love.timer') -- not loaded by default in Love2D threads

local function push_event(event)
	rx_channel:push(event)
end

local ossl_ok, ossl = pcall(require, 'openssl_ffi')
if not ossl_ok or not ossl.available() then
	push_event({ type = 'fatal_error', message = 'OpenSSL FFI not available in launcher thread' })
	return
end

local crypto_ok, crypto = pcall(require, 'anticheat.crypto')
if not crypto_ok then
	push_event({ type = 'fatal_error', message = 'failed to load anticheat.crypto: ' .. tostring(crypto) })
	return
end

local json_lib_ok, json_lib = pcall(require, 'json')

-- Only ever needs to encode this channel's own fixed, flat
-- {string/number} message shapes (hello/heartbeat) - not a general-purpose
-- JSON encoder. Prefers Steamodded's real json.lib when require('json')
-- resolves in this isolated thread Lua state; falls back to a minimal,
-- purpose-built encoder if it doesn't (untested whether it reliably does -
-- this fallback means correctness never depends on that either way).
local function encode_json(tbl)
	if json_lib_ok and json_lib and json_lib.encode then
		local ok, result = pcall(json_lib.encode, tbl)
		if ok then
			return result
		end
	end
	local parts = {}
	for k, v in pairs(tbl) do
		local encoded
		if type(v) == 'number' or type(v) == 'boolean' then
			encoded = tostring(v)
		elseif type(v) == 'string' then
			encoded = '"' .. v:gsub('[\\"]', '\\%0') .. '"'
		else
			error('encode_json fallback: unsupported value type for key ' .. tostring(k))
		end
		parts[#parts + 1] = '"' .. tostring(k) .. '":' .. encoded
	end
	return '{' .. table.concat(parts, ',') .. '}'
end

local function hex_decode(hex)
	return (hex:gsub('%x%x', function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

local secret = hex_decode(setup.secret_hex or '')
if #secret ~= 32 then
	push_event({ type = 'fatal_error', message = 'invalid secret length after hex decode' })
	return
end

local NONCE_LEN = 32
local FRAME_LEN_PREFIX = 4
local HEARTBEAT_INTERVAL = 5.0
local LOST_THRESHOLD = 15.0
local PROTOCOL_VERSION = 1
local INFO_MOD_TO_LAUNCHER = 'BET-RankedSupervisor-v1-mod2launcher'
local INFO_LAUNCHER_TO_MOD = 'BET-RankedSupervisor-v1-launcher2mod'

local sock = socket.tcp()
sock:settimeout(5)
local connect_ok, connect_err = sock:connect('127.0.0.1', tonumber(setup.port))
if not connect_ok then
	push_event({ type = 'fatal_error', message = 'connect failed: ' .. tostring(connect_err) })
	return
end
sock:settimeout(0.05) -- short timeout for the poll loop below

local mod_nonce = ossl.random_bytes(NONCE_LEN)
if not mod_nonce then
	push_event({ type = 'fatal_error', message = 'failed to generate nonce' })
	return
end
local send_ok = sock:send(mod_nonce)
if not send_ok then
	push_event({ type = 'fatal_error', message = 'failed to send nonce' })
	return
end

-- Blocking (within the 5s connect-phase timeout) read of exactly n bytes -
-- only used for the one-time nonce exchange below, before the main loop's
-- non-blocking pump_socket() takes over for everything after.
local recv_buffer = ''
local function read_exact(n, deadline)
	while #recv_buffer < n do
		if socket.gettime() > deadline then
			return nil, 'timed out waiting for launcher nonce'
		end
		local chunk, err, partial = sock:receive(4096)
		if chunk then
			recv_buffer = recv_buffer .. chunk
		elseif err == 'timeout' then
			if partial and #partial > 0 then
				recv_buffer = recv_buffer .. partial
			end
		else
			return nil, err
		end
	end
	local result = recv_buffer:sub(1, n)
	recv_buffer = recv_buffer:sub(n + 1)
	return result
end

local launcher_nonce, nonce_err = read_exact(NONCE_LEN, socket.gettime() + 5)
if not launcher_nonce then
	push_event({ type = 'fatal_error', message = 'failed reading launcher nonce: ' .. tostring(nonce_err) })
	return
end

local salt = mod_nonce .. launcher_nonce
local key_mod_to_launcher, key_err1 = crypto.hkdf_sha256(secret, salt, INFO_MOD_TO_LAUNCHER)
local key_launcher_to_mod, key_err2 = crypto.hkdf_sha256(secret, salt, INFO_LAUNCHER_TO_MOD)
if not key_mod_to_launcher or not key_launcher_to_mod then
	push_event({ type = 'fatal_error', message = 'key derivation failed: ' .. tostring(key_err1 or key_err2) })
	return
end

local send_counter = 0
local recv_counter = 0

-- 12-byte GCM nonce: 4 zero bytes + 8-byte big-endian counter - same
-- convention as the launcher's C++ side (see rankedsupervisor.cpp's
-- counterToNonce()).
local function counter_to_nonce(counter)
	local chars = { '\0', '\0', '\0', '\0' }
	for shift = 56, 0, -8 do
		chars[#chars + 1] = string.char(math.floor(counter / (2 ^ shift)) % 256)
	end
	return table.concat(chars)
end

local function send_frame(payload)
	local plaintext = encode_json(payload)
	local nonce = counter_to_nonce(send_counter)
	local ciphertext = ossl.aes256gcm_encrypt(key_mod_to_launcher, nonce, plaintext)
	if not ciphertext then
		return false
	end
	send_counter = send_counter + 1

	local len = #ciphertext
	local prefix = string.char(
		math.floor(len / 16777216) % 256,
		math.floor(len / 65536) % 256,
		math.floor(len / 256) % 256,
		len % 256
	)
	sock:send(prefix .. ciphertext)
	return true
end

local function pump_socket()
	local chunk, err, partial = sock:receive(4096)
	if chunk then
		recv_buffer = recv_buffer .. chunk
		return true
	elseif err == 'timeout' then
		if partial and #partial > 0 then
			recv_buffer = recv_buffer .. partial
		end
		return true
	else
		return false, err -- 'closed', or a real socket error
	end
end

local function try_consume_frame()
	if #recv_buffer < FRAME_LEN_PREFIX then
		return nil
	end
	local b1, b2, b3, b4 = recv_buffer:byte(1, 4)
	local frame_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
	if #recv_buffer < FRAME_LEN_PREFIX + frame_len then
		return nil
	end
	local ciphertext = recv_buffer:sub(FRAME_LEN_PREFIX + 1, FRAME_LEN_PREFIX + frame_len)
	recv_buffer = recv_buffer:sub(FRAME_LEN_PREFIX + frame_len + 1)
	return ciphertext
end

-- Fire our own hello immediately - see this file's header comment on why
-- mutual auth doesn't need an extra round trip beyond each side
-- independently decrypting the other's hello.
send_frame({ type = 'hello', protocol_version = PROTOCOL_VERSION })

local running = true
local authenticated = false
local supervision_lost = false
local last_received = socket.gettime()
local last_heartbeat_sent = 0

while running do
	-- 1. Drain commands from the main thread (non-blocking).
	while true do
		local cmd = tx_channel:pop()
		if not cmd then
			break
		end
		if cmd.cmd == 'shutdown' then
			running = false
		end
	end
	if not running then
		break
	end

	-- 2. Pump the socket.
	local pump_ok, pump_err = pump_socket()
	if not pump_ok then
		push_event({ type = 'fatal_error', message = 'connection lost: ' .. tostring(pump_err) })
		break
	end

	-- 3. Process any complete frames.
	while true do
		local ciphertext = try_consume_frame()
		if not ciphertext then
			break
		end

		local nonce = counter_to_nonce(recv_counter)
		local plaintext = ossl.aes256gcm_decrypt(key_launcher_to_mod, nonce, ciphertext)
		if not plaintext then
			push_event({ type = 'log', message = 'failed to decrypt a frame from the launcher (tampered/desynced)' })
			if not authenticated then
				push_event({ type = 'fatal_error', message = 'authentication failed' })
				running = false
			elseif not supervision_lost then
				supervision_lost = true
				push_event({ type = 'supervision_lost' })
			end
		else
			recv_counter = recv_counter + 1
			last_received = socket.gettime()
			if supervision_lost then
				supervision_lost = false
				push_event({ type = 'supervision_restored' })
			end
			if not authenticated then
				authenticated = true
				push_event({ type = 'authenticated' })
			end
		end
	end
	if not running then
		break
	end

	-- 4. Periodic heartbeat send.
	local now = socket.gettime()
	if authenticated and (now - last_heartbeat_sent) >= HEARTBEAT_INTERVAL then
		send_frame({ type = 'heartbeat', ts = math.floor(now * 1000) })
		last_heartbeat_sent = now
	end

	-- 5. Watchdog for the launcher going silent - the mod's half of the
	-- "heartbeat going both ways" requirement (the launcher's own
	-- watchdog, symmetric to this, lives in rankedsupervisor.cpp).
	if authenticated and not supervision_lost and (now - last_received) > LOST_THRESHOLD then
		supervision_lost = true
		push_event({ type = 'supervision_lost' })
	end

	love.timer.sleep(0.02)
end

sock:close()
