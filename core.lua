MPAPI = SMODS.current_mod

-- Add mod root, lib/ and networking/ to package.path so the MQTT thread can
-- require("mqtt") (vendored luamqtt at lib/mqtt/init.lua) and require("openssl_ffi")
package.path = MPAPI.path
	.. '/?.lua;'
	.. MPAPI.path
	.. '/?/init.lua;'
	.. MPAPI.path
	.. '/lib/?.lua;'
	.. MPAPI.path
	.. '/lib/?/init.lua;'
	.. MPAPI.path
	.. '/networking/?.lua;'
	.. package.path

-----------------------------
-- CORE FUNCTIONS
-----------------------------

function MPAPI.sendDebugMessage(msg)
	sendDebugMessage(msg, MPAPI.id)
end

function MPAPI.sendWarnMessage(msg)
	sendWarnMessage(msg, MPAPI.id)
end

-- Dedups by path: NFS.getDirectoryItemsInfo's item order within a directory
-- is not guaranteed (confirmed live -- see
-- BalatroMultiplayerSpeed/objects/replay_log/record.lua's own comment on the
-- same hazard within a SINGLE mod's directory scan), so a handful of
-- api/replay/*.lua files with a real load-order dependency (codes.lua must
-- run before generic_codes.lua/framing_codes.lua, which call MPAPI.RLOG_CODE(...)
-- at file-load time) are explicitly preloaded in order below, before the
-- general recursive api/ scan. This guard makes that scan's later re-visit of
-- the same paths a silent no-op instead of re-running (and, for codes.lua,
-- wiping MPAPI.RLOGCodes out from under the codes already registered into it).
MPAPI._loaded_files = {}
MPAPI._loaded_file_results = {}

-- Returns the same result every time, including on a dedup-skipped repeat
-- call (previously returned nil on any call after the first, which is safe
-- for a callsite that only cares about the load side effect but crashes one
-- that needs the module table on every call, e.g. networking/mqtt_client.lua
-- and anticheat/launcher_channel.lua both calling this for
-- lib/thread_preload.lua after core.lua's own load_mpapi_dir('lib') already
-- loaded it once during bootstrap - confirmed live: 'attempt to index local
-- thread_preload (a nil value)' crashing mqtt_client.lua:start_thread() and
-- the launcher-integrity relay thread setup identically, every time, since
-- neither ever gets a first, non-deduped call).
function MPAPI.load_mpapi_file(file)
	if MPAPI._loaded_files[file] then return MPAPI._loaded_file_results[file] end
	MPAPI._loaded_files[file] = true
	local chunk, err = SMODS.load_file(file, MPAPI.id)
	if not chunk then
		error('MPAPI: failed to find or compile file \'' .. file .. '\': ' .. tostring(err), 0)
	end
	local ok, result = pcall(chunk)
	if not ok then
		error('MPAPI: failed to execute file \'' .. file .. '\': ' .. tostring(result), 0)
	end
	MPAPI._loaded_file_results[file] = result
	return result
end

function MPAPI.load_mpapi_dir(directory, recursive)
	recursive = recursive or false

	local dir_path = MPAPI.path .. '/' .. directory
	local items = NFS.getDirectoryItemsInfo(dir_path)

	for _, item in ipairs(items) do
		local path = directory .. '/' .. item.name
		if item.type ~= 'directory' then
			MPAPI.load_mpapi_file(path)
		elseif recursive then
			MPAPI.load_mpapi_dir(path, recursive)
		end
	end
end

-----------------------------
-- DOMAIN & CONTRACTS
-----------------------------

-- Load enums and contracts first: networking and api modules reference them at
-- load time (e.g. networking/connection.lua uses MPAPI.ConnectionState).
MPAPI.load_mpapi_dir('domain', true)
MPAPI.load_mpapi_dir('contracts', true)

-----------------------------
-- NETWORKING
-----------------------------

MPAPI.networking = {}

MPAPI.load_mpapi_file('networking/openssl_ffi.lua')

if MPAPI.networking.openssl_ffi then
	MPAPI.sendDebugMessage('OpenSSL FFI module loaded')

	local available = MPAPI.networking.openssl_ffi.available()

	if available then
		local ctx, err = MPAPI.networking.openssl_ffi.new_context({ verify = false })
		if ctx then
			MPAPI.networking.openssl_ffi.free_context(ctx)
		else
			MPAPI.sendWarnMessage('SSL context creation FAILED: ' .. tostring(err))
		end
	end
else
	MPAPI.sendWarnMessage('OpenSSL FFI module failed to load')
end

MPAPI.load_mpapi_file('networking/mqtt_client.lua')

if MPAPI.networking.mqtt_client then
	MPAPI.sendDebugMessage('MQTT client wrapper loaded')
else
	MPAPI.sendWarnMessage('MQTT client wrapper failed to load')
end

MPAPI.load_mpapi_file('networking/steam.lua')

if MPAPI.networking.steam then
	MPAPI.sendDebugMessage('Steam module loaded (G.STEAM available after love.load)')
else
	MPAPI.sendWarnMessage('Steam module failed to load')
end

MPAPI.load_mpapi_file('networking/api_client.lua')
MPAPI.load_mpapi_file('networking/connection.lua')

-----------------------------
-- FILE LOADING & STARTUP
-----------------------------

function MPAPI.update()
	-- This will be intentionally hooked by other files in the mod
end

MPAPI._internal = {}

-----------------------------
-- RANKED-MODE ANTI-CHEAT (launcher<->mod supervision channel)
-----------------------------

-- Entirely inert unless BET_RANKED_SUPERVISOR_PORT/_SECRET are set (a
-- Ranked-mode launch via BET only) - see anticheat/launcher_channel.lua's
-- header comment. Loaded here (after the MPAPI.update stub above, before
-- lib/api/ui) since it chain-wraps MPAPI.update itself, the same
-- convention api/connection/lifecycle.lua uses for the MQTT client.
MPAPI.load_mpapi_file('anticheat/crypto.lua')
MPAPI.load_mpapi_file('anticheat/launcher_channel.lua')

MPAPI.load_mpapi_dir('lib')

-- Ordered preload for api/replay's load-order-sensitive files (see
-- load_mpapi_file's dedup comment above) -- everything else under api/ has no
-- such dependency and is fine left to the general recursive scan below.
MPAPI.load_mpapi_file('api/replay/recorder.lua')
MPAPI.load_mpapi_file('api/replay/codes.lua')
MPAPI.load_mpapi_file('api/replay/area_utils.lua')

MPAPI.load_mpapi_dir('api', true)
MPAPI.load_mpapi_dir('ui', true)

-- Load dev overrides if the dev/ directory exists (stripped in release builds) --
-- absence here is expected, so guard explicitly rather than relying on
-- load_mpapi_file's (now-fatal) missing-file path.
if NFS.getInfo(MPAPI.path .. '/dev/init.lua') then
	MPAPI.load_mpapi_file('dev/init.lua')
end

G.E_MANAGER:add_event(Event({
	blockable = false,
	blocking = false,
	no_delete = true,
	func = function()
		MPAPI.update()
	end,
}))

G.E_MANAGER:add_event(Event({
	blockable = false,
	blocking = false,
	func = function()
		if not G.STEAM then
			return false
		end
		MPAPI._internal.set_ready(true)
		MPAPI.connect()
		MPAPI._internal.run_ready_callbacks()
		return true
	end,
}))
