--[[
    RFC 5869 HKDF (Extract-and-Expand), built on the OpenSSL FFI HMAC-SHA256
    primitive added in networking/openssl_ffi.lua. A standard, well-known
    construction assembled from a vetted primitive - not invented crypto.

    Mirrors Source/Launcher/src/anticheat/cryptoprimitives.cpp's
    hkdfSha256() on the launcher side exactly (same salt/info conventions,
    same 32-byte output), so both ends of the Ranked-mode launcher<->mod
    supervision channel derive identical keys from the same inputs.

    Loaded standalone (no MPAPI dependency for its own logic - only used to
    read/log via MPAPI when available), same convention as openssl_ffi.lua.
]]

local ffi_ok = pcall(require, 'ffi')
if not ffi_ok then
	local stub = { available = function() return false end }
	if MPAPI then
		MPAPI.anticheat = MPAPI.anticheat or {}
		MPAPI.anticheat.crypto = stub
	end
	return stub
end

local openssl_ffi
if MPAPI and MPAPI.networking and MPAPI.networking.openssl_ffi then
	openssl_ffi = MPAPI.networking.openssl_ffi
else
	openssl_ffi = require('openssl_ffi')
end

local M = {}

local SHA256_LEN = 32
local AES256_KEY_LEN = 32

-- RFC 5869 HKDF-Extract then HKDF-Expand in one call - every call site in
-- this channel wants a single derived key from (secret, salt, info), no
-- caller needs the intermediate PRK. Always returns exactly 32 bytes (this
-- channel only ever derives AES-256 keys). Returns nil+err on any HMAC
-- failure (e.g. OpenSSL unavailable).
function M.hkdf_sha256(secret, salt, info)
	-- HKDF-Extract: PRK = HMAC-Hash(salt, IKM)
	local prk, err = openssl_ffi.hmac_sha256(salt, secret)
	if not prk then
		return nil, err
	end

	-- HKDF-Expand: T(i) = HMAC-Hash(PRK, T(i-1) || info || i), OKM = T(1..N)
	-- truncated. With output length == SHA256_LEN this loop always runs
	-- exactly once, but it's written generally per RFC 5869 rather than
	-- special-cased to N=1 (matches the C++ side's hkdfSha256() for the
	-- same reason).
	local okm = ''
	local previous_block = ''
	local counter = 1
	while #okm < AES256_KEY_LEN do
		local input = previous_block .. info .. string.char(counter)
		local block, hmac_err = openssl_ffi.hmac_sha256(prk, input)
		if not block then
			return nil, hmac_err
		end
		previous_block = block
		okm = okm .. block
		counter = counter + 1
	end

	return okm:sub(1, AES256_KEY_LEN)
end

function M.available()
	return openssl_ffi.available()
end

if MPAPI then
	MPAPI.anticheat = MPAPI.anticheat or {}
	MPAPI.anticheat.crypto = M
end
return M
