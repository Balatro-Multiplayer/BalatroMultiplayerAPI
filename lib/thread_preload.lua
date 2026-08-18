--[[
    Helper for handing Lua modules that live inside a mounted mod zip to a
    background love.thread.

    Root cause this works around: BET (the launcher) deploys mods as a
    <Mods folder>/<name>.zip, not an extracted folder (see BET's own
    CLAUDE.md - "Mods are deployed as a zip, not extracted"). Steamodded
    mounts that zip virtually, so MPAPI.path resolves to something like
    "Multiplayer API.zip.mnt/" - a path only love.filesystem's own APIs
    (NFS.read() included) can actually read through. The main thread's
    require() is transparently hooked by LÖVE2D/Steamodded to resolve
    through that virtual mount; a background love.thread gets a minimal,
    un-hooked Lua environment - its stock require() uses raw io.open,
    which can't see inside a mounted zip at all (the only real file on
    disk from the OS's perspective is the opaque .zip itself).

    mqtt_client.lua already demonstrates the correct workaround for its
    own thread's *bootstrap* file: read the source via NFS.read() (works
    fine in the main thread) and hand love.thread.newThread() the source
    text directly, never a path. This module generalizes that same
    technique to an entire module tree (mqtt's own dependency tree,
    anticheat.crypto, openssl_ffi, ...): read every .lua file under a
    directory via NFS.read() here in the main thread, and return a flat
    {module_name = source_text} table the caller sends through the
    thread's channel. The receiving thread then registers each entry into
    its own package.preload[module_name] = function(...) return
    load(source)(...) end *before* calling require() - see
    networking/mqtt_thread.lua and anticheat/launcher_thread.lua for the
    receiving side (duplicated there, not required from this file, since
    a background thread can't require() a module living in the mount
    either - the same chicken-and-egg problem this file exists to solve
    in the first place).
]]

local M = {}

-- Reads every .lua file under MPAPI.path .. relative_dir, recursively,
-- and returns { [module_name] = source_text, ... } using the standard
-- dotted module-name convention: module_prefix for relative_dir's own
-- init.lua (or the single file directly at relative_dir, if it's a file
-- not a directory of files), module_prefix .. "." .. name for a sibling
-- file/subdirectory. Matches exactly what require(module_prefix) /
-- require(module_prefix .. ".client") etc. would look for.
function M.build_preload_table(relative_dir, module_prefix)
	local result = {}
	local base_path = MPAPI.path .. '/' .. relative_dir

	local function walk(subdir, mod_path)
		local items = NFS.getDirectoryItemsInfo(base_path .. subdir)
		for _, item in ipairs(items) do
			if item.type == 'directory' then
				walk(subdir .. '/' .. item.name, mod_path .. '.' .. item.name)
			elseif item.name:match('%.lua$') then
				local name = item.name:gsub('%.lua$', '')
				local full_mod = (name == 'init') and mod_path or (mod_path .. '.' .. name)
				local file_path = base_path .. subdir .. '/' .. item.name
				local content = NFS.read(file_path)
				if content then
					result[full_mod] = content
				end
			end
		end
	end

	walk('', module_prefix)
	return result
end

-- Single-file convenience for a module that isn't a whole directory tree
-- (openssl_ffi.lua, anticheat/crypto.lua) - same {module_name = source}
-- shape, so callers can just table.merge the results together before
-- sending.
function M.read_single_module(relative_path, module_name)
	local content = NFS.read(MPAPI.path .. '/' .. relative_path)
	if not content then
		return {}
	end
	return { [module_name] = content }
end

return M
