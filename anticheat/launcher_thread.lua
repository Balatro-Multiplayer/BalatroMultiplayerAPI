--[[
    Ranked-mode launcher<->mod supervision channel - network thread.
    Receives commands on tx_channel, sends events on rx_channel. Messages
    here are Lua *tables*, not SEP-joined strings: this
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

-- pkg_path above still points into Steamodded's virtual zip mount, which
-- this thread's stock require()/io.open can't actually read through (see
-- lib/thread_preload.lua's comment on the main thread) - register the
-- pre-read source the main thread sent right after the setup table (as
-- its own message - love.thread Channels don't support nested tables,
-- so this couldn't just be a field on setup above), before requiring
-- anything that lives in the mount (openssl_ffi, anticheat.crypto below).
local preload = tx_channel:demand()
if type(preload) == 'table' then
	for mod_name, source in pairs(preload) do
		if not package.preload[mod_name] then
			package.preload[mod_name] = function(...)
				local chunk = assert(load(source, '@' .. mod_name))
				return chunk(...)
			end
		end
	end
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

-- Minimal recursive-descent JSON decoder used only as a fallback when
-- json_lib.decode isn't available in this isolated thread Lua state (see
-- encode_json's own comment above on why that's possible at all, even
-- though json_lib is expected to always resolve in the real Steamodded
-- runtime). Only implements what this channel's own messages ever need:
-- objects, strings (with the same handful of escapes encode_json emits),
-- numbers, booleans, null, and nested objects - no
-- arrays, since nothing on this channel ever sends one.
local function decode_json_fallback(str)
	local pos = 1
	local parse_value

	local function skip_ws()
		while pos <= #str and str:sub(pos, pos):match('%s') do
			pos = pos + 1
		end
	end

	local function parse_string()
		pos = pos + 1 -- opening quote
		local buf = {}
		while pos <= #str do
			local c = str:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(buf)
			elseif c == '\\' then
				local nextc = str:sub(pos + 1, pos + 1)
				local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n', t = '\t', r = '\r' }
				buf[#buf + 1] = escapes[nextc] or nextc
				pos = pos + 2
			else
				buf[#buf + 1] = c
				pos = pos + 1
			end
		end
		error('decode_json_fallback: unterminated string')
	end

	local function parse_number()
		local start = pos
		while pos <= #str and str:sub(pos, pos):match('[%d%.%-%+eE]') do
			pos = pos + 1
		end
		return tonumber(str:sub(start, pos - 1))
	end

	local function parse_object()
		pos = pos + 1 -- opening brace
		local obj = {}
		skip_ws()
		if str:sub(pos, pos) == '}' then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			pos = pos + 1 -- colon
			skip_ws()
			obj[key] = parse_value()
			skip_ws()
			local c = str:sub(pos, pos)
			if c == ',' then
				pos = pos + 1
			elseif c == '}' then
				pos = pos + 1
				break
			else
				error('decode_json_fallback: malformed object near position ' .. pos)
			end
		end
		return obj
	end

	parse_value = function()
		skip_ws()
		local c = str:sub(pos, pos)
		if c == '{' then
			return parse_object()
		elseif c == '"' then
			return parse_string()
		elseif str:sub(pos, pos + 3) == 'true' then
			pos = pos + 4
			return true
		elseif str:sub(pos, pos + 4) == 'false' then
			pos = pos + 5
			return false
		elseif str:sub(pos, pos + 3) == 'null' then
			pos = pos + 4
			return nil
		else
			return parse_number()
		end
	end

	local ok, result = pcall(parse_value)
	if not ok then
		return nil
	end
	return result
end

local function decode_json(str)
	if json_lib_ok and json_lib and json_lib.decode then
		local ok, result = pcall(json_lib.decode, str)
		if ok then
			return result
		end
	end
	return decode_json_fallback(str)
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

-- No attempt below is ever fatal: the launcher keeps listening for the life
-- of the game process and the main thread (anticheat/launcher_channel.lua)
-- decides when to stop waiting, so this thread just keeps retrying until
-- it's told to stop trying (bypass) or to shut down. Slow machines routinely
-- reach this point long before the launcher is ready to talk, or the other
-- way round; neither is an error.
local CONNECT_TIMEOUT = 1.0
local HANDSHAKE_TIMEOUT = 2.0
local RETRY_DELAY = 0.25
local LOG_THROTTLE = 5.0

local sock = nil
local recv_buffer = ''
local key_mod_to_launcher, key_launcher_to_mod
local send_counter, recv_counter = 0, 0
local authenticated = false
local supervision_lost = false
local last_received = 0
local last_heartbeat_sent = 0
local handshake_deadline = 0

local function close_session()
	if sock then
		pcall(function()
			sock:close()
		end)
	end
	sock = nil
	recv_buffer = ''
	authenticated = false
	supervision_lost = false
end

-- Blocking (bounded by `deadline`) read of exactly n bytes - only used for
-- the nonce exchange, before the main loop's non-blocking pump_socket()
-- takes over for everything after.
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
	if not sock then
		return false
	end
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

-- One full connect + nonce exchange + key derivation + hello. Returns true
-- once our hello is sent (authentication completes later, in the main loop,
-- when the launcher's own hello decrypts), or false + a reason.
local function try_connect()
	local s = socket.tcp()
	s:settimeout(CONNECT_TIMEOUT)
	local connect_ok, connect_err = s:connect('127.0.0.1', tonumber(setup.port))
	if not connect_ok then
		s:close()
		return false, 'connect failed: ' .. tostring(connect_err)
	end
	s:settimeout(0.05) -- short timeout for the poll loop below
	sock = s
	recv_buffer = ''

	local mod_nonce = ossl.random_bytes(NONCE_LEN)
	if not mod_nonce then
		close_session()
		return false, 'failed to generate nonce'
	end
	if not sock:send(mod_nonce) then
		close_session()
		return false, 'failed to send nonce'
	end

	local launcher_nonce, nonce_err = read_exact(NONCE_LEN, socket.gettime() + CONNECT_TIMEOUT)
	if not launcher_nonce then
		close_session()
		return false, 'failed reading launcher nonce: ' .. tostring(nonce_err)
	end

	local salt = mod_nonce .. launcher_nonce
	local k1, key_err1 = crypto.hkdf_sha256(secret, salt, INFO_MOD_TO_LAUNCHER)
	local k2, key_err2 = crypto.hkdf_sha256(secret, salt, INFO_LAUNCHER_TO_MOD)
	if not k1 or not k2 then
		close_session()
		return false, 'key derivation failed: ' .. tostring(key_err1 or key_err2)
	end
	key_mod_to_launcher, key_launcher_to_mod = k1, k2

	send_counter, recv_counter = 0, 0
	authenticated = false
	supervision_lost = false
	last_received = socket.gettime()
	last_heartbeat_sent = 0
	handshake_deadline = socket.gettime() + HANDSHAKE_TIMEOUT

	-- Fire our own hello immediately - see this file's header comment on why
	-- mutual auth doesn't need an extra round trip beyond each side
	-- independently decrypting the other's hello.
	send_frame({ type = 'hello', protocol_version = PROTOCOL_VERSION })
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

local running = true
local bypass_requested = false -- player gave up: reconnect only until the launcher is told, once
local bypass_sent = false
local next_attempt = 0
local last_fail_log = 0

while running do
	-- 1. Drain commands from the main thread (non-blocking).
	while true do
		local cmd = tx_channel:pop()
		if not cmd then
			break
		end
		if cmd.cmd == 'shutdown' then
			running = false
		elseif cmd.cmd == 'bypass' then
			bypass_requested = true
		elseif cmd.cmd == 'answer_challenge' then
			-- Pure relay - this thread never computes a signature itself, it
			-- only forwards what the server issued (via Nakama, on the main
			-- thread) to the launcher, which is the only party holding the
			-- secret needed to answer it. Defensive check: only meaningful
			-- post-handshake, though launcher_channel.lua's own pending-
			-- challenge queue means this shouldn't actually trigger.
			if authenticated and not bypass_requested then
				local send_attempted = send_frame({
					type = 'challenge_request',
					challenge_id = cmd.challenge_id,
					kind = cmd.kind,
					nonce = cmd.nonce,
					player_id = cmd.player_id,
				})
				push_event({
					type = 'log',
					message = '[integrity] challenge '
						.. tostring(cmd.challenge_id)
						.. (send_attempted and ' send attempted to launcher' or ' NOT forwarded: encrypt failed'),
				})
			else
				push_event({
					type = 'log',
					message = '[integrity] challenge '
						.. tostring(cmd.challenge_id)
						.. ' dropped in launcher thread: handshake not complete',
				})
				-- Without this the main thread would wait for an answer that is never coming.
				push_event({ type = 'challenge_answered', challenge_id = cmd.challenge_id, error = 'not_connected' })
			end
		end
	end
	if not running then
		break
	end

	local now = socket.gettime()

	-- 2. (Re)connect while we have no session.
	if not sock and (not bypass_requested or not bypass_sent) and now >= next_attempt then
		local ok, reason = try_connect()
		if not ok then
			next_attempt = socket.gettime() + RETRY_DELAY
			if now - last_fail_log >= LOG_THROTTLE then
				last_fail_log = now
				push_event({ type = 'log', message = 'launcher not reachable yet, retrying: ' .. tostring(reason) })
			end
		end
	end

	if sock then
		-- 3. Pump the socket.
		local pump_ok, pump_err = pump_socket()
		if not pump_ok then
			push_event({ type = 'disconnected', message = 'connection lost: ' .. tostring(pump_err) })
			close_session()
			next_attempt = now + RETRY_DELAY
		end
	end

	-- 4. Process any complete frames.
	while sock do
		local ciphertext = try_consume_frame()
		if not ciphertext then
			break
		end

		local nonce = counter_to_nonce(recv_counter)
		local plaintext = ossl.aes256gcm_decrypt(key_launcher_to_mod, nonce, ciphertext)
		if not plaintext then
			push_event({ type = 'log', message = 'failed to decrypt a frame from the launcher (tampered/desynced)' })
			if not authenticated then
				-- A half-finished attempt; drop it and start a fresh one.
				push_event({ type = 'disconnected', message = 'authentication failed' })
				close_session()
				next_attempt = now + RETRY_DELAY
			elseif not supervision_lost then
				supervision_lost = true
				push_event({ type = 'supervision_lost' })
			end
			break
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
			else
				-- Every post-auth frame needs decoding to find out what it is
				-- (heartbeat vs challenge_response) - a plain heartbeat's
				-- content is otherwise unused, last_received above is already
				-- all it needed to trigger.
				local decode_ok, frame = pcall(decode_json, plaintext)
				if not decode_ok or type(frame) ~= 'table' then
					push_event({ type = 'log', message = '[integrity] undecodable frame from launcher ignored' })
				end
				if decode_ok and type(frame) == 'table' and frame.type == 'challenge_response' then
					push_event({
						type = 'challenge_answered',
						challenge_id = frame.challenge_id,
						signature = frame.signature,
						-- Only ever present for a ranked_readiness response
						-- (see RankedSupervisor::sendReadinessChallengeResponse())
						-- - nil for every other kind.
						launcher_current = frame.launcher_current,
						mods_current = frame.mods_current,
						stale_mod_ids = frame.stale_mod_ids,
						error = frame.error,
					})
				end
			end
		end
	end

	now = socket.gettime()

	-- 5. A connection that never completes its hello is abandoned and retried
	-- from scratch (a half-open socket from an earlier attempt would
	-- otherwise sit there for the rest of the Run).
	if sock and not authenticated and now > handshake_deadline then
		push_event({ type = 'disconnected', message = 'handshake did not complete in time' })
		close_session()
		next_attempt = now + RETRY_DELAY
	end

	-- 6. Tell the launcher the player gave up, as soon as there's a session
	-- to tell it over (step 2 reconnects until it has). It never reconnects
	-- after this, and the socket is deliberately left open so heartbeats keep
	-- flowing - closing it would read as a heartbeat loss on the launcher side.
	if bypass_requested and authenticated and not bypass_sent then
		bypass_sent = send_frame({ type = 'ranked_bypassed' })
	end

	-- 7. Periodic heartbeat send.
	if authenticated and (now - last_heartbeat_sent) >= HEARTBEAT_INTERVAL then
		send_frame({ type = 'heartbeat', ts = math.floor(now * 1000) })
		last_heartbeat_sent = now
	end

	-- 8. Watchdog for the launcher going silent - the mod's half of the
	-- "heartbeat going both ways" requirement (the launcher's own
	-- watchdog, symmetric to this, lives in rankedsupervisor.cpp).
	if authenticated and not supervision_lost and (now - last_received) > LOST_THRESHOLD then
		supervision_lost = true
		push_event({ type = 'supervision_lost' })
	end

	love.timer.sleep(0.02)
end

close_session()
