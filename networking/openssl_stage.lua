--[[
    Stages the bundled macOS OpenSSL libraries out of a zip-mounted mod.

    macOS loads libssl/libcrypto only by absolute path (openssl_ffi.lua), and a
    zip-mounted mod has no real networking/ folder. So the main thread copies
    the two dylibs into the save directory and points BET_OPENSSL_DYLIB_DIR at
    the copy. The variable is process-wide, so worker threads see it too.
    Runs on the main thread only, before openssl_ffi.lua loads.
]]

local STAGE_DIR_NAME = 'MPAPI_openssl'
local LIBRARY_FILES = { 'libssl.3.dylib', 'libcrypto.3.dylib' }

local M = {}

-- Pure. Staging is needed only on macOS, when the launcher gave no library
-- directory and the mod's own networking/ folder is not a real directory.
function M.plan(facts)
	if facts.os == 'OSX' and not facts.env_dir and not facts.bundled_readable then
		return 'stage'
	end
	return 'skip'
end

-- deps: read(file_name) -> bytes|nil (from the mounted mod's networking/),
-- save_dir, write(relative_path, bytes) -> boolean, setenv(name, value).
-- Returns the staged directory, or nil and a message.
function M.stage(deps)
	local contents = {}
	for _, file_name in ipairs(LIBRARY_FILES) do
		local bytes = deps.read(file_name)
		if not bytes then
			return nil, 'bundled ' .. file_name .. ' not found in the mod'
		end
		contents[file_name] = bytes
	end
	for _, file_name in ipairs(LIBRARY_FILES) do
		if not deps.write(STAGE_DIR_NAME .. '/' .. file_name, contents[file_name]) then
			return nil, 'could not write ' .. file_name .. ' to the save directory'
		end
	end
	local dir = deps.save_dir:gsub('/*$', '') .. '/' .. STAGE_DIR_NAME
	deps.setenv('BET_OPENSSL_DYLIB_DIR', dir)
	return dir
end

-- The effectful wiring: love.filesystem reads the mount, libc sets the variable.
function M.stage_if_needed()
	local ffi = require('ffi')
	local mod_networking = MPAPI.path:gsub('/*$', '') .. '/networking/'
	local probe = io.open(mod_networking .. LIBRARY_FILES[1], 'rb')
	if probe then
		probe:close()
	end
	local plan = M.plan({
		os = ffi.os,
		env_dir = os.getenv('BET_OPENSSL_DYLIB_DIR'),
		bundled_readable = probe ~= nil,
	})
	if plan == 'skip' then
		return
	end

	-- Steamodded mounts a zip under a path that may be relative to Mods/.
	local mount_roots = { (MPAPI.path:gsub('/*$', '')) }
	local relative = MPAPI.path:match('[/\\]Mods[/\\](.+)$')
	if relative then
		mount_roots[#mount_roots + 1] = (relative:gsub('\\', '/'):gsub('/*$', ''))
	end

	pcall(ffi.cdef, 'int setenv(const char *name, const char *value, int overwrite);')
	local dir, err = M.stage({
		read = function(file_name)
			for _, root in ipairs(mount_roots) do
				local bytes = love.filesystem.read(root .. '/networking/' .. file_name)
				if bytes then
					return bytes
				end
			end
		end,
		save_dir = love.filesystem.getSaveDirectory(),
		write = function(relative_path, bytes)
			love.filesystem.createDirectory(STAGE_DIR_NAME)
			return love.filesystem.write(relative_path, bytes)
		end,
		setenv = function(name, value)
			ffi.C.setenv(name, value, 1)
		end,
	})
	if dir then
		MPAPI.sendDebugMessage('[OpenSSL] Staged macOS libraries from the zipped mod to ' .. dir)
	else
		MPAPI.sendWarnMessage('[OpenSSL] Could not stage macOS libraries from the zipped mod: ' .. tostring(err))
	end
end

return M
