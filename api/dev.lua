-- MPAPI.dev: the seam the Dev mod (BalatroMultiplayerServer, dev/client/)
-- uses to point the client at a Dev server and pick a test account. It is a
-- contract with the Server repo, like the wire contracts. Call it at mod load
-- time: MPAPI connects once Steam is up, after every mod has loaded.
MPAPI.dev = MPAPI.dev or {}

local SERVER_DEFAULT_KEYS = { host = true, port = true, secure = true, server_key = true, web_url = true }

local function conn()
	MPAPI._internal.conn = MPAPI._internal.conn or {}
	return MPAPI._internal.conn
end

local function mark_dev_mod_loaded()
	MPAPI._internal.dev_mod_loaded = true
end

-- Replaces the given endpoint defaults (host, port, secure, server_key,
-- web_url; keys left out keep MPAPI's value) and marks the server as not
-- Official, so the client sends a Device login and skips the Ranked launcher
-- check. A player's use_custom_server config still takes precedence.
function MPAPI.dev.set_server_defaults(opts)
	for key in pairs(opts) do
		if not SERVER_DEFAULT_KEYS[key] then
			error('MPAPI.dev.set_server_defaults: unknown key ' .. tostring(key))
		end
	end
	local C = conn()
	for key, value in pairs(opts) do
		C.SERVER_DEFAULTS[key] = value
	end
	C.not_official_marked = true
	mark_dev_mod_loaded()
end

-- The account the client logs in as. Exactly one of:
--   { id = <id> } or { name = <steamName> }: a Device login as that test
--     account (device id "bmp-dev-<id or name>"), so several game instances
--     on one Steam account act as different players;
--   { steam = true }: Steam login, even though the server is not Official.
function MPAPI.dev.set_identity(identity)
	local given = 0
	for _, key in ipairs({ 'id', 'name', 'steam' }) do
		if identity[key] ~= nil then
			given = given + 1
		end
	end
	if given ~= 1 or (identity.steam ~= nil and identity.steam ~= true) then
		error('MPAPI.dev.set_identity: pass exactly one of id, name or steam = true')
	end
	local C = conn()
	if identity.steam then
		C.dev_identity = nil
		C.force_steam_login = true
	else
		C.dev_identity = identity.id and { playerId = identity.id } or { steamName = identity.name }
		C.force_steam_login = false
	end
	mark_dev_mod_loaded()
end

-- Starts the in-game scenario runner (dev/scenario/runner.lua) for the
-- BMP_SCENARIO=<mod_id>:<name> selector. Contributors only: release builds
-- strip dev/. Call it at mod load time, so its hooks are in place before the
-- splash screen.
function MPAPI.dev.start_scenario()
	MPAPI.load_mpapi_file('dev/scenario/runner.lua')
end
