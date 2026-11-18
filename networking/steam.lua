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

-----------------------------
-- STEAM PROVIDER
-----------------------------

-- One mod can register as the Steam provider: it gives the Steam id, Steam
-- name and Steam tickets in place of the Steam client, and wins even while the
-- Steam client runs. The provider's tickets are checked by the server like any
-- other Steam ticket.
--
-- provider = {
--   mod = 'ModName',            -- named in the refusal warning of a second registration
--   ready = function() -> bool, -- can give a ticket now
--   not_ready_message = function() -> string,
--                               -- why it is not ready, already localized; the menu shows it
--   get_steam_id = function() -> id | nil, err
--   get_persona_name = function() -> name | nil, err
--   get_auth_ticket = function() -> { ticket = hex, handle = n } | nil, err
--   cancel_auth_ticket = function(handle)
--   settled = function() -> bool,
--                               -- optional: false while the provider is still starting up
--                               -- (for example, logging in from a stored login). The first
--                               -- connect at startup waits until it is true.
-- }
-- The four get/cancel functions return what the Steam client versions below return.
--
-- The provider calls steam.provider_changed() whenever ready() or settled() may
-- have changed. MPAPI then connects a disconnected client: once when the
-- provider becomes ready (again after a logout too), and the deferred first
-- connect when the provider settles. A live connection is never touched.
local provider = nil
-- The first connect at startup is waiting for the provider to settle.
local startup_waiting = false
-- ready() when provider_changed last looked, so only a change to ready connects.
local was_ready = false

local function mod_name(p)
	return tostring(p.mod or 'unknown mod')
end

-- Returns true when `p` is now the provider, false when another mod holds it.
function steam.register_provider(p)
	if provider then
		warn('Steam provider from ' .. mod_name(p) .. ' refused: ' .. mod_name(provider) .. ' is already the provider')
		return false
	end
	provider = p
	log('Steam provider registered by ' .. mod_name(p))
	return true
end

-- The registered provider, or nil.
function steam.provider()
	return provider
end

-- Startup (core.lua): true when the first connect must wait for a provider
-- that is still settling; provider_changed() runs it later.
function steam.defer_startup_connect()
	if not provider then
		return false
	end
	was_ready = provider.ready() and true or false
	startup_waiting = provider.settled ~= nil and not provider.settled()
	return startup_waiting
end

function steam.provider_changed()
	if not provider then
		return
	end
	local ready = provider.ready() and true or false
	local became_ready = ready and not was_ready
	was_ready = ready
	if MPAPI.connection_state.state ~= MPAPI.ConnectionState.DISCONNECTED then
		return
	end
	if MPAPI.account_button then
		MPAPI.account_button:update()
	end
	if startup_waiting then
		if provider.settled and not provider.settled() then
			return
		end
		startup_waiting = false
		MPAPI.connect()
	elseif became_ready and MPAPI.is_ready() then
		MPAPI.disconnect()
		MPAPI.connect(MPAPI.get_last_opts() or {})
	end
end

function steam.available()
	if provider then
		return provider.ready() and true or false
	end
	return get_luasteam() ~= nil
end

-- Why available() is false: an MPAPI.OfflineReason and, for a provider, its
-- own message text.
function steam.unavailable_reason()
	if provider then
		return MPAPI.OfflineReason.STEAM_PROVIDER_NOT_READY, provider.not_ready_message()
	end
	return MPAPI.OfflineReason.STEAM_NOT_RUNNING
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

-- With a provider registered it answers instead of the Steam client. Same
-- return shapes, so the connection code does not change.
for _, name in ipairs({ 'get_steam_id', 'get_persona_name', 'get_auth_ticket', 'cancel_auth_ticket' }) do
	local client_version = steam[name]
	steam[name] = function(...)
		if provider then
			return provider[name](...)
		end
		return client_version(...)
	end
end

MPAPI.networking.steam = steam
