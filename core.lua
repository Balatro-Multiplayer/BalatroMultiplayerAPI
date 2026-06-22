MPAPI = SMODS.current_mod

-- Add mod root and networking/ to package.path so the MQTT thread can
-- require("mqtt") (luamqtt at mqtt/init.lua) and require("openssl_ffi")
package.path = MPAPI.path .. '/?.lua;' .. MPAPI.path .. '/?/init.lua;' .. MPAPI.path .. '/networking/?.lua;' .. package.path

-----------------------------
-- CORE FUNCTIONS
-----------------------------

function MPAPI.sendDebugMessage(msg)
	sendDebugMessage(msg, MPAPI.id)
end

function MPAPI.sendWarnMessage(msg)
	sendWarnMessage(msg, MPAPI.id)
end

function MPAPI.load_mpapi_file(file)
	local chunk, err = SMODS.load_file(file, MPAPI.id)
	if chunk then
		local ok, func = pcall(chunk)
		if ok then
			return func
		else
			MPAPI.sendWarnMessage('Failed to process file: ' .. func)
		end
	else
		MPAPI.sendWarnMessage('Failed to find or compile file: ' .. tostring(err))
	end
	return nil
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

MPAPI.load_mpapi_file('networking/token_store.lua')
MPAPI.load_mpapi_file('networking/api_client.lua')
MPAPI.load_mpapi_file('networking/connection.lua')

-----------------------------
-- FILE LOADING & STARTUP
-----------------------------

function MPAPI.update()
	-- This will be intentionally hooked by other files in the mod
end

MPAPI._internal = {}

MPAPI.load_mpapi_dir('lib')
MPAPI.load_mpapi_dir('api')
MPAPI.load_mpapi_dir('ui')

-- Load dev overrides if the dev/ directory exists (stripped in release builds)
local dev_init = MPAPI.load_mpapi_file('dev/init.lua')

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
		if next(SMODS.find_mod('Integration')) then
			local chunk = SMODS.load_file('testing/init.lua', MPAPI.id)
			if chunk then
				pcall(chunk)
			end
		end
		return true
	end,
}))
