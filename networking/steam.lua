local steam = {}

local function log(msg)
	if MPAPI and MPAPI.sendDebugMessage then
		MPAPI.sendDebugMessage('[Steam] ' .. msg)
	end
end

local function warn(msg)
	if MPAPI and MPAPI.sendWarnMessage then
		MPAPI.sendWarnMessage('[Steam] ' .. msg)
	end
end

local function get_luasteam()
	return G and G.STEAM
end

function steam.available()
	return get_luasteam() ~= nil
end

function steam.get_steam_id()
	local st = get_luasteam()
	if not st or not st.user then
		return nil, 'G.STEAM not available'
	end
	local id = st.user.getSteamID()
	if not id then
		return nil, 'getSteamID returned nil'
	end
	return tostring(id)
end

function steam.get_persona_name()
	local st = get_luasteam()
	if not st or not st.friends then
		return nil, 'G.STEAM not available'
	end
	local id = st.user.getSteamID()
	if not id then
		return nil, 'getSteamID returned nil'
	end
	local name = st.friends.getFriendPersonaName(id)
	if not name or name == '' or name == '[unknown]' then
		return nil, 'Could not get persona name'
	end
	return name
end

local ffi_ok, ffi = pcall(require, 'ffi')
local auth_ticket_available = false

if ffi_ok then
	local function safe_cdef(decl)
		local ok, err = pcall(ffi.cdef, decl)
		if not ok then
			log('cdef failed: ' .. tostring(err):sub(1, 120))
		end
		return ok
	end

	local IS_WINDOWS = (ffi.os == 'Windows')

	if IS_WINDOWS then
		-- Win32: resolve symbols from the already-loaded steam_api64.dll
		safe_cdef('void* GetModuleHandleA(const char* lpModuleName);')
		safe_cdef('void* GetProcAddress(void* hModule, const char* lpProcName);')
	else
		-- POSIX (macOS/Linux): dlopen/dlsym live in libc / libSystem, which is
		-- always loaded, so they are reachable through the default ffi.C namespace.
		safe_cdef('void* dlopen(const char* filename, int flag);')
		safe_cdef('void* dlsym(void* handle, const char* symbol);')
	end

	safe_cdef('typedef struct ISteamUser ISteamUser;')
	safe_cdef('typedef uint32_t HAuthTicket;')
	safe_cdef([[
        typedef ISteamUser* (*SteamUserAccessor_t)();
        typedef HAuthTicket (*GetAuthSessionTicket_t)(
            ISteamUser* self,
            void* pTicket,
            int cbMaxTicket,
            uint32_t* pcbTicket,
            void* pSteamNetworkingIdentity
        );
        typedef void (*CancelAuthTicket_t)(ISteamUser* self, HAuthTicket hAuthTicket);
    ]])

	-- Cached function pointers (resolved on first use)
	local _steam_user_ptr = nil
	local _get_auth_ticket_fn = nil
	local _cancel_auth_ticket_fn = nil

	-- Candidate names for the loaded Steam library, per platform. The leaf name
	-- is enough: the game/luasteam has already pulled it into the process, so
	-- dlopen/GetModuleHandleA resolve to the existing image without reloading.
	local steam_module_names
	if IS_WINDOWS then
		steam_module_names = { 'steam_api64.dll', 'steam_api64', 'steam_api.dll', 'steam_api' }
	elseif ffi.os == 'OSX' then
		steam_module_names = { 'libsteam_api.dylib', 'steam_api', 'libsteam_api' }
	else
		steam_module_names = { 'libsteam_api.so', 'steam_api', 'libsteam_api' }
	end

	-- RTLD_LAZY is 0x1 on both macOS and Linux. RTLD_DEFAULT (search all loaded
	-- images) is the last-resort fallback if dlopen-by-leaf-name fails.
	local RTLD_LAZY = 0x1
	local RTLD_DEFAULT = (ffi.os == 'OSX') and ffi.cast('void*', -2) or ffi.cast('void*', 0)

	-- Returns (handle, name) for the loaded Steam library, or nil on failure.
	-- `name` doubles as the success flag so we never test a possibly-NULL handle
	-- pointer for truthiness (RTLD_DEFAULT is NULL on Linux).
	local function get_steam_module()
		for _, name in ipairs(steam_module_names) do
			local ok, h
			if IS_WINDOWS then
				ok, h = pcall(function()
					return ffi.C.GetModuleHandleA(name)
				end)
			else
				ok, h = pcall(function()
					return ffi.C.dlopen(name, RTLD_LAZY)
				end)
			end
			if ok and h ~= nil then
				return h, name
			end
		end
		if not IS_WINDOWS then
			-- Symbols are already in the process even if dlopen couldn't find the
			-- file on disk; let dlsym search every loaded image.
			return RTLD_DEFAULT, 'RTLD_DEFAULT'
		end
		return nil
	end

	-- Resolve a named symbol from a module handle, cross-platform. The symbol
	-- name is the plain C name on both sides (dlsym prepends the Mach-O '_').
	local function get_proc(handle, name)
		if IS_WINDOWS then
			return ffi.C.GetProcAddress(handle, name)
		else
			return ffi.C.dlsym(handle, name)
		end
	end

	local function resolve_game_steam()
		if _steam_user_ptr then
			return true
		end

		-- Get a handle to the game's already-loaded Steam library.
		local hModule, modName = get_steam_module()
		if not modName then
			warn('Could not locate loaded Steam library (steam_api64.dll / libsteam_api.dylib) in process')
			return false
		end
		log("Got game's Steam library handle via " .. modName)

		-- Resolve the ISteamUser accessor (try version strings)
		local accessor_names = {
			'SteamAPI_SteamUser_v023',
			'SteamAPI_SteamUser_v022',
			'SteamAPI_SteamUser_v021',
			'SteamAPI_SteamUser_v020',
		}

		local user_ptr = nil
		for _, name in ipairs(accessor_names) do
			local proc_ok, proc = pcall(function()
				return get_proc(hModule, name)
			end)
			if proc_ok and proc ~= nil and proc then
				log('Resolved Steam accessor: ' .. name)
				local accessor = ffi.cast('SteamUserAccessor_t', proc)
				local call_ok, ptr = pcall(accessor)
				if call_ok and ptr ~= nil and ptr then
					log('ISteamUser pointer obtained: ' .. tostring(ptr))
					user_ptr = ptr
					break
				else
					log('  accessor returned NULL')
				end
			end
		end

		if not user_ptr then
			warn("Could not get ISteamUser from the game's Steam library")
			return false
		end

		_steam_user_ptr = user_ptr

		-- Resolve GetAuthSessionTicket
		local gat_ok, gat_proc = pcall(function()
			return get_proc(hModule, 'SteamAPI_ISteamUser_GetAuthSessionTicket')
		end)
		if gat_ok and gat_proc ~= nil and gat_proc then
			_get_auth_ticket_fn = ffi.cast('GetAuthSessionTicket_t', gat_proc)
			log('Resolved GetAuthSessionTicket')
		end

		-- Resolve CancelAuthTicket
		local cat_ok, cat_proc = pcall(function()
			return get_proc(hModule, 'SteamAPI_ISteamUser_CancelAuthTicket')
		end)
		if cat_ok and cat_proc ~= nil and cat_proc then
			_cancel_auth_ticket_fn = ffi.cast('CancelAuthTicket_t', cat_proc)
			log('Resolved CancelAuthTicket')
		end

		auth_ticket_available = (_get_auth_ticket_fn ~= nil)
		return auth_ticket_available
	end

	--- Get a Steam auth session ticket as a hex string.
	function steam.get_auth_ticket()
		if not resolve_game_steam() then
			return nil, 'Could not resolve Steam auth functions from the game Steam library'
		end

		local max_ticket = 1024
		local buf = ffi.new('uint8_t[?]', max_ticket)
		local actual_len = ffi.new('uint32_t[1]')

		local ok, handle = pcall(function()
			return _get_auth_ticket_fn(_steam_user_ptr, buf, max_ticket, actual_len, nil)
		end)

		if not ok then
			return nil, 'GetAuthSessionTicket call failed: ' .. tostring(handle)
		end

		if handle == 0 then
			return nil, 'GetAuthSessionTicket returned invalid handle'
		end

		local len = actual_len[0]
		local hex_parts = {}
		for i = 0, len - 1 do
			hex_parts[#hex_parts + 1] = string.format('%02x', buf[i])
		end

		return {
			ticket = table.concat(hex_parts),
			handle = tonumber(handle),
		}
	end

	--- Cancel a previously obtained auth ticket.
	function steam.cancel_auth_ticket(handle)
		if not _cancel_auth_ticket_fn or not _steam_user_ptr or not handle then
			return
		end
		pcall(function()
			_cancel_auth_ticket_fn(_steam_user_ptr, handle)
		end)
	end
else
	-- No FFI — auth tickets not available, but Steam ID/name still work via G.STEAM
	function steam.get_auth_ticket()
		return nil, 'FFI not available for auth tickets'
	end
	function steam.cancel_auth_ticket() end
end

MPAPI.networking.steam = steam
