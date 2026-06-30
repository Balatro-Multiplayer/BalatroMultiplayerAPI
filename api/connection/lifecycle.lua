-- Connection lifecycle: server-endpoint resolution, connect/disconnect/reconnect,
-- the state-change handler that drives the connection_state view, and the
-- on_loaded / ready callback queue.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn
C.ready = C.ready or false
C.ready_callbacks = C.ready_callbacks or {}
C.state_change_callbacks = C.state_change_callbacks or {}

-- Production endpoints. For local development against a server running inside WSL2,
-- override these via MPAPI.connect{ api_url = ..., mqtt_broker = ... }: prefer the
-- literal 127.0.0.1 over 'localhost', since on Windows 'localhost' resolves to IPv6
-- ::1 first, which does not reach WSL2 and eats a ~21s TCP SYN timeout per connection
-- before falling back to IPv4.
local SERVER_DEFAULTS = {
	api_url = 'https://new.balatromp.com',
	mqtt_broker = 'mqtt.balatromp.com',
	mqtt_port = 8883,
	mqtt_secure = true,
}

-- Resolve a self-hosted/local server from SMODS mod config (for development). Returns the
-- effective endpoints when MPAPI.config.use_custom_server is on, or nil to fall through to the
-- official SERVER_DEFAULTS. The host is shared by the API and MQTT broker; the API URL is built
-- from it. Explicit MPAPI.connect{...} opts still take precedence over this (see connect()).
-- Dev-server ports are fixed by convention, so the config carries only a host and a single
-- secure flag; the scheme and ports are derived from it (secure -> https + MQTT 8883/TLS;
-- plain -> http + MQTT 1883).
local CUSTOM_API_PORT = 8788
local CUSTOM_MQTT_TLS_PORT = 8883
local CUSTOM_MQTT_PLAIN_PORT = 1883

local function config_server()
	local c = MPAPI.config or {}
	if not c.use_custom_server then
		return nil
	end
	local host = c.custom_server_url or '127.0.0.1'
	local secure = c.custom_server_secure
	if secure == nil then
		secure = true
	end
	return {
		api_url = (secure and 'https://' or 'http://') .. host .. ':' .. CUSTOM_API_PORT,
		mqtt_broker = host,
		mqtt_port = secure and CUSTOM_MQTT_TLS_PORT or CUSTOM_MQTT_PLAIN_PORT,
		mqtt_secure = secure,
	}
end

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function()
	if C.mqtt_instance then
		C.mqtt_instance:update()
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

	if not MPAPI.networking.mqtt_client then
		MPAPI.sendWarnMessage('MQTT client module not available')
		return
	end

	-- Precedence: explicit connect{...} opts > SMODS-config custom server > official defaults.
	local custom = config_server()

	local mqtt_broker = opts.mqtt_broker or (custom and custom.mqtt_broker) or SERVER_DEFAULTS.mqtt_broker
	local mqtt_port = opts.mqtt_port or (custom and custom.mqtt_port) or SERVER_DEFAULTS.mqtt_port
	local mqtt_secure = SERVER_DEFAULTS.mqtt_secure
	if opts.mqtt_secure ~= nil then
		mqtt_secure = opts.mqtt_secure
	elseif custom and custom.mqtt_secure ~= nil then
		mqtt_secure = custom.mqtt_secure
	end

	C.mqtt_instance = MPAPI.networking.mqtt_client.new({
		broker = mqtt_broker,
		port = mqtt_port,
		secure = mqtt_secure,
	})

	local api = MPAPI.networking.api_client.new(C.mqtt_instance, opts.api_url or (custom and custom.api_url) or SERVER_DEFAULTS.api_url)

	C.connection = MPAPI.networking.connection.new({
		mqtt_client = C.mqtt_instance,
		api_client = api,
		steam = MPAPI.networking.steam,
		token_store = MPAPI.networking.token_store,
		config = {
			mqtt_broker = mqtt_broker,
			mqtt_port = mqtt_port,
			mqtt_secure = mqtt_secure,
			force_login = opts.force_login or false,
			dev_name = opts.dev_name or nil,
			auto_login = MPAPI.config.auto_login ~= false,
		},
	})

	C.connection.on_state_change = connection_on_state_change

	C.connection:connect()
end

MPAPI.disconnect = function()
	if C.connection then
		C.connection:disconnect()
	end
	if C.mqtt_instance then
		C.mqtt_instance:disconnect()
		C.mqtt_instance = nil
	end
	C.connection = nil
	MPAPI.connection_state.state = MPAPI.ConnectionState.DISCONNECTED
	C.reset_state_vars()
	C.set_status_text()
end

-- Tear down the current connection and reconnect with the same opts. Used to apply a server
-- change (e.g. toggling the local dev server in the config) without a game restart.
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

MPAPI.get_mqtt = function()
	return C.mqtt_instance
end

MPAPI.get_connection = function()
	return C.connection
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

	-- Auto-create lobby object on reconnection
	if new_state == MPAPI.ConnectionState.CONNECTED and context.reconnected_lobby and MPAPI._internal.create_reconnected_lobby then
		MPAPI._internal.create_reconnected_lobby(context.reconnected_lobby)
	end

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
	elseif new_state == MPAPI.ConnectionState.LOGIN_AVAILABLE then
		MPAPI.sendDebugMessage('Login available (auto-login off) for: ' .. tostring(context.steam_name))
	elseif new_state == MPAPI.ConnectionState.AUTHENTICATING then
		MPAPI.sendDebugMessage('Authenticating...')
	elseif new_state == MPAPI.ConnectionState.CONNECTING then
		MPAPI.sendDebugMessage('Connecting to MQTT broker...')
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
