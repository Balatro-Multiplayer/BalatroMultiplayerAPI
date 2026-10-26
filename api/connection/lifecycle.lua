-- Connection lifecycle: server-endpoint resolution, connect/disconnect/reconnect,
-- the state-change handler that drives the connection_state view, and the
-- on_loaded / ready callback queue.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn
C.ready = C.ready or false
C.ready_callbacks = C.ready_callbacks or {}
C.state_change_callbacks = C.state_change_callbacks or {}

-- Production endpoints: the Nakama server the game talks to, and the website
-- (log and report links). Each can be overridden by MPAPI.connect{...} opts
-- or, with the config key use_custom_server set, the mod config keys
-- server_host, server_port, server_secure, nakama_server_key and web_url;
-- dev/init.lua points dev builds at the local stack. For a server inside WSL2 prefer the literal 127.0.0.1 over
-- 'localhost': on Windows 'localhost' resolves to IPv6 ::1 first, which does
-- not reach WSL2 and eats a ~21s TCP SYN timeout before falling back to IPv4.
C.SERVER_DEFAULTS = {
	host = 'nakama.balatromp.com',
	port = 443,
	secure = true,
	server_key = 'defaultkey',
	web_url = 'https://new.balatromp.com',
}

local CONFIG_KEYS = {
	host = 'server_host',
	port = 'server_port',
	secure = 'server_secure',
	server_key = 'nakama_server_key',
	web_url = 'web_url',
}

-- Set by the Dev mod (ticket 04: MPAPI.dev.set_server_defaults) when it
-- points the client at its own server.
C.not_official_marked = C.not_official_marked or false

local function uses_custom_server()
	return MPAPI.config ~= nil and MPAPI.config.use_custom_server == true
end

-- Whether the client talks to the Official server. Only the Official server
-- takes Steam login and needs the launcher for Ranked; any other server
-- (Community or Dev) takes Device login.
function C.is_official_server()
	return not uses_custom_server() and not C.not_official_marked
end

-- One endpoint setting. Precedence: connect{...} opts > mod config (only
-- with use_custom_server) > defaults.
local function setting(opts, key)
	if opts[key] ~= nil then
		return opts[key]
	end
	if uses_custom_server() then
		local configured = MPAPI.config[CONFIG_KEYS[key]]
		if configured ~= nil then
			return configured
		end
	end
	return C.SERVER_DEFAULTS[key]
end

-- The endpoints a connect with `opts` uses. Pure but for the config read.
function C.resolve_server(opts)
	opts = opts or {}
	return {
		host = setting(opts, 'host'),
		port = tonumber(setting(opts, 'port')),
		secure = setting(opts, 'secure') and true or false,
		server_key = setting(opts, 'server_key'),
		web_url = setting(opts, 'web_url'),
	}
end

-- The Nakama client for `server`. The SDK is loaded on first use.
local function create_nakama_client(server)
	local sdk = MPAPI.load_mpapi_file('networking/nakama_sdk.lua').load()
	C.nakama_engine = sdk.engine
	return sdk.nakama.create_client({
		host = server.host,
		port = server.port,
		use_ssl = server.secure,
		username = server.server_key,
		password = '',
		engine = sdk.engine,
	})
end

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function()
	if C.nakama_engine then
		C.nakama_engine.update()
		MPAPI.networking.nakama_lobby.update()
	end
	MPAPI_update_ref()
end

local connection_on_state_change
local log_state_update
local run_new_state_user_callbacks

MPAPI.on_loaded = function(fn)
	-- Capture the mod registering this callback. on_loaded callbacks run deferred
	-- (after SMODS has finished loading), by which point SMODS.current_mod no longer
	-- points at the caller. GameObjects created in the callback (e.g. a mod loading
	-- its ActionTypes/GameModes here) would otherwise be tagged with the wrong mod,
	-- which breaks per-lobby action routing (lobby._action_types filters by mod id).
	local owner_mod = SMODS.current_mod
	local wrapped = function()
		local prev = SMODS.current_mod
		SMODS.current_mod = owner_mod or prev
		local ok, err = pcall(fn)
		SMODS.current_mod = prev
		if not ok then
			MPAPI.sendWarnMessage('on_loaded callback error: ' .. tostring(err))
		end
	end
	if C.ready then
		return wrapped()
	end
	C.ready_callbacks[#C.ready_callbacks + 1] = wrapped
end

MPAPI.on_connection_state_change = function(fn)
	C.state_change_callbacks[#C.state_change_callbacks + 1] = fn
end

MPAPI.connect = function(opts)
	opts = opts or {}
	C.last_opts = opts

	if C.connection and C.connection:get_state() ~= MPAPI.ConnectionState.DISCONNECTED then
		MPAPI.sendWarnMessage('Already connected or connecting')
		return
	end

	C.server = C.resolve_server(opts)
	C.connection = MPAPI.networking.connection.new({
		steam = MPAPI.networking.steam,
		nakama_client = create_nakama_client(C.server),
		official = C.is_official_server(),
		config = { secure = C.server.secure },
	})

	C.connection.on_state_change = connection_on_state_change

	C.connection:connect()
end

MPAPI.disconnect = function()
	if C.connection then
		C.connection:disconnect()
	end
	C.connection = nil
	MPAPI.connection_state.state = MPAPI.ConnectionState.DISCONNECTED
	MPAPI.connection_state.offline_reason = nil
	C.reset_state_vars()
	C.set_status_text()
end

-- Tear down the current connection and reconnect with the same opts. Used to apply a server
-- change without a game restart.
MPAPI.reconnect = function()
	local opts = C.last_opts or {}
	MPAPI.disconnect()
	MPAPI.connect(opts)
end

MPAPI.is_connected = function()
	if C.connection then
		return C.connection:get_state() == MPAPI.ConnectionState.CONNECTED
	end
	return false
end

-- The one launcher-integrity flag safe for another mod to gate a Ranked
-- queue button on - reflects the *server's* verdict on the most recent
-- challenge response (see anticheat/launcher_channel.lua's A.server_verified
-- doc comment), not just "BET answered something". False for Casual, a
-- non-BET launch, or before the server's first login-challenge response has
-- landed - none of those should ever show an enabled Ranked queue button.
MPAPI.is_launcher_verified = function()
	return MPAPI.anticheat ~= nil and MPAPI.anticheat.server_verified == true
end

-- The website's base URL, for links to a run's log or a report.
MPAPI.get_web_url = function()
	return (C.server or C.resolve_server(C.last_opts)).web_url
end

MPAPI.get_connection = function()
	return C.connection
end

-- The Nakama session from the last login, or nil when not logged in.
MPAPI.get_nakama_session = function()
	return C.connection and C.connection.nakama_session or nil
end

-- The id this player's replay logs and lobby rosters are keyed by: the
-- Nakama user id.
MPAPI.get_replay_player_id = function()
	local conn = C.connection
	return conn and conn.player_id or nil
end

MPAPI.get_last_opts = function()
	return C.last_opts
end

MPAPI.is_ready = function()
	return C.ready
end

MPAPI.get_privileges = function()
	return MPAPI.connection_state.privileges
end

MPAPI._internal.set_ready = function(ready)
	C.ready = ready
end

MPAPI._internal.run_ready_callbacks = function()
	for _, fn in ipairs(C.ready_callbacks) do
		local ok, err = pcall(fn)
		if not ok then
			MPAPI.sendWarnMessage('on_loaded callback error: ' .. tostring(err))
		end
	end
	C.ready_callbacks = {}
end

connection_on_state_change = function(new_state, context)
	context = context or {}

	MPAPI.connection_state.state = new_state
	MPAPI.connection_state.offline_reason = new_state == MPAPI.ConnectionState.DISCONNECTED and context.offline_reason or nil
	if new_state == MPAPI.ConnectionState.CONNECTED or context.player_update then
		MPAPI.connection_state.player_id = C.connection.player_id or ''
		MPAPI.connection_state.steam_name = MPAPI.truncate(C.connection.steam_name or '', 20)
		MPAPI.connection_state.discord_name = MPAPI.truncate(C.connection.discord_name or '', 20)
		MPAPI.connection_state.is_temp = C.connection.is_temp or false
		MPAPI.connection_state.use_discord_name = C.connection.use_discord_name or false
		MPAPI.connection_state.preferred_joker = C.connection.preferred_joker or 'j_joker'
		MPAPI.connection_state.privileges = C.connection.privileges
		MPAPI.connection_state.chat_enabled = C.connection.chat_enabled or false
		MPAPI.connection_state.chat_blocked = C.connection.chat_blocked or false
		MPAPI.connection_state.mute_list = C.connection.mute_list or {}
	end

	C.set_status_text()

	C.update_display_name()

	if new_state == MPAPI.ConnectionState.TOS_REQUIRED then
		MPAPI.connection_state.tos_is_update = context.tos_update or false
	end

	if new_state ~= context.old_state then
		if new_state ~= MPAPI.ConnectionState.CONNECTED then
			C.reset_state_vars()
		end
		log_state_update(new_state, context)
	end

	-- No auto-create of the reconnected lobby object here anymore: doing this
	-- unconditionally raced with (and always won against) ui/reconnect_prompt.lua's
	-- own Rejoin/Reconnect flow -- by the time any state_change_callback (including
	-- the prompt's) saw CONNECTED, the lobby was already silently recreated,
	-- so MPAPI.replay-based mid-match rejoin's own "refuse if already connected
	-- to a real lobby" guard always fired and the fast-forward-then-live-handoff
	-- never got a chance to run (confirmed live). ui/reconnect_prompt.lua now
	-- owns this entirely: it asks the player first, and only calls
	-- MPAPI._internal.create_reconnected_lobby itself once they choose Reconnect
	-- (after first checking whether there's an active RLOG run to rejoin
	-- instead, which needs to run BEFORE the plain lobby object exists).

	run_new_state_user_callbacks(new_state, context)

	for _, fn in ipairs(C.state_change_callbacks) do
		local ok, err = pcall(fn, new_state, context)
		if not ok then
			MPAPI.sendWarnMessage('on_connection_state_change callback error: ' .. tostring(err))
		end
	end
end

log_state_update = function(new_state, context)
	if context.error then
		MPAPI.sendWarnMessage('Connection error: ' .. tostring(context.error))
	elseif new_state == MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendDebugMessage('Connected! Player ID: ' .. tostring(C.connection.player_id))
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED then
		MPAPI.sendDebugMessage('Disconnected from server')
	elseif new_state == MPAPI.ConnectionState.TOS_REQUIRED then
		MPAPI.sendDebugMessage('ToS acceptance required for: ' .. tostring(context.steam_name))
	elseif new_state == MPAPI.ConnectionState.AUTHENTICATING then
		MPAPI.sendDebugMessage('Authenticating...')
	elseif new_state == MPAPI.ConnectionState.CONNECTING then
		MPAPI.sendDebugMessage('Connecting to the server...')
	end
end

run_new_state_user_callbacks = function(new_state, context)
	if context.error and C.last_opts.on_error then
		C.last_opts.on_error(context.error)
	elseif new_state == MPAPI.ConnectionState.CONNECTED and context.reconnected_lobby and C.last_opts.on_reconnected then
		C.last_opts.on_reconnected(C.connection, context.reconnected_lobby)
	elseif new_state == MPAPI.ConnectionState.CONNECTED and C.last_opts.on_connected then
		C.last_opts.on_connected(C.connection)
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED and context.old_state == MPAPI.ConnectionState.CONNECTED and C.last_opts.on_disconnected then
		C.last_opts.on_disconnected()
	end
end
