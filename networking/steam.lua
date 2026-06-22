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

	safe_cdef('void* GetModuleHandleA(const char* lpModuleName);')
	safe_cdef('void* GetProcAddress(void* hModule, const char* lpProcName);')

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

	local function resolve_game_steam()
		if _steam_user_ptr then
			return true
		end

		-- Get the game's loaded steam_api64.dll handle
		local ok, hModule = pcall(function()
			return ffi.C.GetModuleHandleA('steam_api64.dll')
		end)
		if not ok or not hModule or hModule == nil then
			-- Try without extension
			ok, hModule = pcall(function()
				return ffi.C.GetModuleHandleA('steam_api64')
			end)
		end
		if not ok or not hModule or hModule == nil or not hModule then
			warn('GetModuleHandleA failed — steam_api64.dll not loaded in process')
			return false
		end
		log("Got game's steam_api64.dll module handle")

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
				return ffi.C.GetProcAddress(hModule, name)
			end)
			if proc_ok and proc ~= nil and proc then
				log('Resolved accessor via GetProcAddress: ' .. name)
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
			warn("Could not get ISteamUser from game's DLL")
			return false
		end

		_steam_user_ptr = user_ptr

		-- Resolve GetAuthSessionTicket
		local gat_ok, gat_proc = pcall(function()
			return ffi.C.GetProcAddress(hModule, 'SteamAPI_ISteamUser_GetAuthSessionTicket')
		end)
		if gat_ok and gat_proc ~= nil and gat_proc then
			_get_auth_ticket_fn = ffi.cast('GetAuthSessionTicket_t', gat_proc)
			log('Resolved GetAuthSessionTicket')
		end

		-- Resolve CancelAuthTicket
		local cat_ok, cat_proc = pcall(function()
			return ffi.C.GetProcAddress(hModule, 'SteamAPI_ISteamUser_CancelAuthTicket')
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
			return nil, 'Could not resolve Steam auth functions from game DLL'
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
