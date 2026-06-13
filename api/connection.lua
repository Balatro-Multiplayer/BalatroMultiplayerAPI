-- Forward declarations for helper functions
local connection_on_state_change
local log_state_update
local update_display_name
local reset_connection_state_variables
local set_connection_state_status_text
local run_new_state_user_callbacks

-----------------------------
-- STATE VARIABLES
-----------------------------

MPAPI.connection_state = {
	state = 'disconnected',
	status_text = localize('k_status_offline'),
	player_id = '',
	display_name = localize('b_retry_connection'),
	steam_name = '',
	discord_name = '',
	is_temp = false,
	use_discord_name = false,
	preferred_joker = 'j_joker',
	privileges = {},
	tos_is_update = false,
	chat_enabled = false,
	chat_blocked = false,
}

local _mqtt_instance = nil
local _connection = nil
local _ready = false
local _ready_callbacks = {}
local _last_opts = nil
local _state_change_callbacks = {}

local SERVER_DEFAULTS = {
	api_url = 'http://localhost:8788',
	mqtt_broker = 'localhost',
	mqtt_port = 8883,
	mqtt_secure = true,
}

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function()
	if _mqtt_instance then
		_mqtt_instance:update()
	end
	MPAPI_update_ref()
end

-----------------------------
-- API FUNCTIONS
-----------------------------

MPAPI.on_loaded = function(fn)
	if _ready then
		return fn()
	end
	_ready_callbacks[#_ready_callbacks + 1] = fn
end

MPAPI.on_connection_state_change = function(fn)
	_state_change_callbacks[#_state_change_callbacks + 1] = fn
end

MPAPI.connect = function(opts)
	opts = opts or {}
	_last_opts = opts

	if _connection and _connection:get_state() ~= 'disconnected' then
		MPAPI.sendWarnMessage('Already connected or connecting')
		return
	end

	if not MPAPI.networking.mqtt_client then
		MPAPI.sendWarnMessage('MQTT client module not available')
		return
	end

	local mqtt_broker = opts.mqtt_broker or SERVER_DEFAULTS.mqtt_broker
	local mqtt_port = opts.mqtt_port or SERVER_DEFAULTS.mqtt_port
	local mqtt_secure = SERVER_DEFAULTS.mqtt_secure
	if opts.mqtt_secure ~= nil then
		mqtt_secure = opts.mqtt_secure
	end

	_mqtt_instance = MPAPI.networking.mqtt_client.new({
		broker = mqtt_broker,
		port = mqtt_port,
		secure = mqtt_secure,
	})

	local api = MPAPI.networking.api_client.new(_mqtt_instance, opts.api_url or SERVER_DEFAULTS.api_url)

	_connection = MPAPI.networking.connection.new({
		mqtt_client = _mqtt_instance,
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

	_connection.on_state_change = connection_on_state_change

	_connection:connect()
end

MPAPI.disconnect = function()
	if _connection then
		_connection:disconnect()
	end
	if _mqtt_instance then
		_mqtt_instance:disconnect()
		_mqtt_instance = nil
	end
	_connection = nil
	MPAPI.connection_state.state = 'disconnected'
	reset_connection_state_variables()
	set_connection_state_status_text()
end

MPAPI.is_connected = function()
	if _connection then
		return _connection:get_state() == 'connected'
	end
	return false
end

MPAPI.get_mqtt = function()
	return _mqtt_instance
end

MPAPI.get_connection = function()
	return _connection
end

MPAPI.get_last_opts = function()
	return _last_opts
end

MPAPI.is_ready = function()
	return _ready
end

MPAPI.get_privileges = function()
	return MPAPI.connection_state.privileges
end

-----------------------------
-- INTERNAL FUNCTIONS
-----------------------------

MPAPI._internal.set_ready = function(ready)
	_ready = ready
end

MPAPI._internal.run_ready_callbacks = function()
	for _, fn in ipairs(_ready_callbacks) do
		local ok, err = pcall(fn)
		if not ok then
			MPAPI.sendWarnMessage('on_loaded callback error: ' .. tostring(err))
		end
	end
	_ready_callbacks = {}
end

MPAPI._internal.get_discord_link_url = function(callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end
	conn.api:get_discord_link_url(conn.jwt_token, callback)
end

MPAPI._internal.set_use_discord_name = function(value, callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end

	conn.api:set_display_name_pref(conn.jwt_token, value, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.display_name = data.player.displayName or conn.steam_name
			conn.use_discord_name = data.player.useDiscordName or false
		end
		MPAPI.connection_state.use_discord_name = conn.use_discord_name

		update_display_name()

		callback(nil, data)
	end)
end

MPAPI._internal.set_preferred_joker = function(value, callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end

	conn.api:set_preferred_joker(conn.jwt_token, value, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.preferred_joker = data.player.preferredJoker or 'j_joker'
		end
		MPAPI.connection_state.preferred_joker = conn.preferred_joker

		callback(nil, data)
	end)
end

MPAPI._internal.unlink_discord = function(callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end

	conn.api:unlink_discord(conn.jwt_token, callback)
end

MPAPI._internal.enable_chat = function(callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end

	conn.api:enable_chat(conn.jwt_token, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.chat_enabled = data.player.chatEnabled or false
			conn.chat_blocked = data.player.chatBlocked or false
			MPAPI.connection_state.chat_enabled = conn.chat_enabled
			MPAPI.connection_state.chat_blocked = conn.chat_blocked
		end

		callback(nil, data)
	end)
end

MPAPI._internal.send_chat_message = function(code, message, callback)
	local conn = _connection
	if not conn or conn:get_state() ~= 'connected' then
		callback('Not connected', nil)
		return
	end
	if not conn.jwt_token then
		callback('No JWT token', nil)
		return
	end

	conn.api:send_chat_message(conn.jwt_token, code, message, callback)
end

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

update_display_name = function()
	if MPAPI.connection_state.state ~= 'connected' then
		if MPAPI.connection_state.state == 'login_available' then
			MPAPI.connection_state.display_name = localize('b_log_in')
		else
			MPAPI.connection_state.display_name = localize('b_retry_connection')
		end
	elseif _connection and _connection.display_name then
		MPAPI.connection_state.display_name = MPAPI.truncate(_connection.display_name, 20)
	elseif MPAPI.connection_state.steam_name ~= '' then
		MPAPI.connection_state.display_name = MPAPI.connection_state.steam_name
	else
		MPAPI.connection_state.display_name = localize('k_unknown')
	end

	if MPAPI.account_button then
		MPAPI.account_button:update()
	end
	if MPAPI.account_overlay then
		MPAPI.account_overlay:update()
	end
end

connection_on_state_change = function(new_state, context)
	context = context or {}

	MPAPI.connection_state.state = new_state
	if new_state == 'connected' or context.player_update then
		MPAPI.connection_state.player_id = _connection.player_id or ''
		MPAPI.connection_state.steam_name = MPAPI.truncate(_connection.steam_name or '', 20)
		MPAPI.connection_state.discord_name = MPAPI.truncate(_connection.discord_name or '', 20)
		MPAPI.connection_state.is_temp = _connection.is_temp or false
		MPAPI.connection_state.use_discord_name = _connection.use_discord_name or false
		MPAPI.connection_state.preferred_joker = _connection.preferred_joker or 'j_joker'
		MPAPI.connection_state.privileges = _connection.privileges
		MPAPI.connection_state.chat_enabled = _connection.chat_enabled or false
		MPAPI.connection_state.chat_blocked = _connection.chat_blocked or false
	end
	set_connection_state_status_text()

	update_display_name()

	if new_state == 'tos_required' then
		MPAPI.connection_state.tos_is_update = context.tos_update or false
	end

	if new_state ~= context.old_state then
		if new_state ~= 'connected' then
			reset_connection_state_variables()
		end
		log_state_update(new_state, context)
	end

	-- Auto-create lobby object on reconnection
	if new_state == 'connected' and context.reconnected_lobby and MPAPI._internal.create_reconnected_lobby then
		MPAPI._internal.create_reconnected_lobby(context.reconnected_lobby)
	end

	run_new_state_user_callbacks(new_state, context)

	for _, fn in ipairs(_state_change_callbacks) do
		local ok, err = pcall(fn, new_state, context)
		if not ok then
			MPAPI.sendWarnMessage('on_connection_state_change callback error: ' .. tostring(err))
		end
	end
end

log_state_update = function(new_state, context)
	if context.error then
		MPAPI.sendWarnMessage('Connection error: ' .. tostring(context.error))
	elseif new_state == 'connected' then
		MPAPI.sendDebugMessage('Connected! Player ID: ' .. tostring(_connection.player_id))
	elseif new_state == 'disconnected' then
		MPAPI.sendDebugMessage('Disconnected from server')
	elseif new_state == 'tos_required' then
		MPAPI.sendDebugMessage('ToS acceptance required for: ' .. tostring(context.steam_name))
	elseif new_state == 'login_available' then
		MPAPI.sendDebugMessage('Login available (auto-login off) for: ' .. tostring(context.steam_name))
	elseif new_state == 'authenticating' then
		MPAPI.sendDebugMessage('Authenticating...')
	elseif new_state == 'connecting' then
		MPAPI.sendDebugMessage('Connecting to MQTT broker...')
	end
end

reset_connection_state_variables = function()
	MPAPI.connection_state.player_id = ''
	MPAPI.connection_state.steam_name = ''
	MPAPI.connection_state.discord_name = ''
	MPAPI.connection_state.is_temp = false
	MPAPI.connection_state.use_discord_name = false
	MPAPI.connection_state.preferred_joker = 'j_joker'
	MPAPI.connection_state.privileges = nil
	MPAPI.connection_state.chat_enabled = false
	MPAPI.connection_state.chat_blocked = false
end

set_connection_state_status_text = function()
	if MPAPI.connection_state.state == 'connected' then
		MPAPI.connection_state.status_text = localize('k_status_connected')
	elseif MPAPI.connection_state.state == 'authenticating' then
		MPAPI.connection_state.status_text = localize('k_status_signing_in')
	elseif MPAPI.connection_state.state == 'connecting' then
		MPAPI.connection_state.status_text = localize('k_status_connecting')
	else
		MPAPI.connection_state.status_text = localize('k_status_offline')
	end
end

run_new_state_user_callbacks = function(new_state, context)
	if context.error and _last_opts.on_error then
		_last_opts.on_error(context.error)
	elseif new_state == 'connected' and context.reconnected_lobby and _last_opts.on_reconnected then
		_last_opts.on_reconnected(_connection, context.reconnected_lobby)
	elseif new_state == 'connected' and _last_opts.on_connected then
		_last_opts.on_connected(_connection)
	elseif new_state == 'disconnected' and context.old_state == 'connected' and _last_opts.on_disconnected then
		_last_opts.on_disconnected()
	end
end
