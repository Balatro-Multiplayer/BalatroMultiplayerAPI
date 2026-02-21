MPAPI = SMODS.current_mod

MPAPI.sendDebugMessage = function(msg)
    sendDebugMessage(msg, MPAPI.id)
end

MPAPI.sendWarnMessage = function(msg)
    sendWarnMessage(msg, MPAPI.id)
end

function MPAPI.load_mpapi_file(file)
	local chunk, err = SMODS.load_file(file, MPAPI.id)
	if chunk then
		local ok, func = pcall(chunk)
		if ok then
			return func
		else
			MPAPI.sendWarnMessage("Failed to process file: " .. func)
		end
	else
		MPAPI.sendWarnMessage("Failed to find or compile file: " .. tostring(err))
	end
	return nil
end

function MPAPI.load_mpapi_dir(directory, recursive)
	recursive = recursive or false

	local dir_path = MPAPI.path .. "/" .. directory
	local items = NFS.getDirectoryItemsInfo(dir_path)

	for _, item in ipairs(items) do
		local path = directory .. "/" .. item.name
		MPAPI.sendDebugMessage("Loading item: " .. path)
		if item.type ~= "directory" then
			MPAPI.load_mpapi_file(path)
		elseif recursive then
			MPAPI.load_mpapi_dir(path, recursive)
		end
	end
end

MPAPI.modules = {}

MPAPI.modules.openssl_ffi = MPAPI.load_mpapi_file("network/openssl_ffi.lua")

if MPAPI.modules.openssl_ffi then
    MPAPI.sendDebugMessage("OpenSSL FFI module loaded")

    local available = MPAPI.modules.openssl_ffi.available()

    if available then
        local ctx, err = MPAPI.modules.openssl_ffi.new_context({ verify = false })
        if ctx then
            MPAPI.modules.openssl_ffi.free_context(ctx)
        else
            MPAPI.sendWarnMessage("SSL context creation FAILED: " .. tostring(err))
        end
    end
else
    MPAPI.sendWarnMessage("OpenSSL FFI module failed to load")
end

MPAPI.modules.mqtt_client = MPAPI.load_mpapi_file("network/mqtt_client.lua")

if MPAPI.modules.mqtt_client then
    MPAPI.sendDebugMessage("MQTT client wrapper loaded")
else
    MPAPI.sendWarnMessage("MQTT client wrapper failed to load")
end

local config = SMODS.current_mod.config
