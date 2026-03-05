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
}

local _mqtt_instance = nil
local _connection = nil
local _ready = false
local _ready_callbacks = {}
local _last_opts = nil

local SERVER_DEFAULTS = {
	api_url = 'http://localhost:8788',
	mqtt_broker = 'localhost',
	mqtt_port = 8883,
	mqtt_secure = true,
}

local MPAPI_update_ref = MPAPI.update
function MPAPI.update()
	if _mqtt_instance then
		_mqtt_instance:update()
	end
	MPAPI_update_ref()
end

-----------------------------
-- API FUNCTIONS
-----------------------------

function MPAPI.on_loaded(fn)
	if _ready then
		return fn()
	end
	_ready_callbacks[#_ready_callbacks + 1] = fn
end

function MPAPI.connect(opts)
	opts = opts or {}
	_last_opts = opts

	if _connection and _connection:get_state() ~= 'disconnected' then
		MPAPI.sendWarnMessage('Already connected or connecting')
		return
	end

	if not MPAPI.modules.mqtt_client then
		MPAPI.sendWarnMessage('MQTT client module not available')
		return
	end

	local mqtt_broker = opts.mqtt_broker or SERVER_DEFAULTS.mqtt_broker
	local mqtt_port = opts.mqtt_port or SERVER_DEFAULTS.mqtt_port
	local mqtt_secure = SERVER_DEFAULTS.mqtt_secure
	if opts.mqtt_secure ~= nil then
		mqtt_secure = opts.mqtt_secure
	end

	_mqtt_instance = MPAPI.modules.mqtt_client.new({
		broker = mqtt_broker,
		port = mqtt_port,
		secure = mqtt_secure,
	})

	local api = MPAPI.modules.api_client.new(_mqtt_instance, opts.api_url or SERVER_DEFAULTS.api_url)

	_connection = MPAPI.modules.connection.new({
		mqtt_client = _mqtt_instance,
		api_client = api,
		steam = MPAPI.modules.steam,
		token_store = MPAPI.modules.token_store,
		config = {
			mqtt_broker = mqtt_broker,
			mqtt_port = mqtt_port,
			mqtt_secure = mqtt_secure,
		},
	})

	_connection.on_state_change = connection_on_state_change

	_connection:connect()
end

function MPAPI.disconnect()
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

function MPAPI.is_connected()
	if _connection then
		return _connection:get_state()
	end
	return 'disconnected'
end

function MPAPI.get_mqtt()
	return _mqtt_instance
end

function MPAPI.get_connection()
	return _connection
end

function MPAPI.get_last_opts()
	return _last_opts
end

function MPAPI.is_ready()
	return _ready
end

-----------------------------
-- INTERNAL FUNCTIONS
-----------------------------

function MPAPI._internal.set_ready(ready)
	_ready = ready
end

function MPAPI._internal.run_ready_callbacks()
	for _, fn in ipairs(_ready_callbacks) do
		local ok, err = pcall(fn)
		if not ok then
			MPAPI.sendWarnMessage('on_loaded callback error: ' .. tostring(err))
		end
	end
	_ready_callbacks = {}
end

function MPAPI._internal.get_discord_link_url(callback)
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

function MPAPI._internal.set_use_discord_name(value, callback)
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

function MPAPI._internal.set_preferred_joker(value, callback)
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

function MPAPI._internal.unlink_discord(callback)
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

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

update_display_name = function()
	if MPAPI.connection_state.state ~= 'connected' then
		MPAPI.connection_state.display_name = localize('b_retry_connection')
		return
	end

	if _connection and _connection.display_name then
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
	end
	set_connection_state_status_text()

	update_display_name()

	if new_state ~= context.old_state then
		if new_state ~= 'connected' then
			reset_connection_state_variables()
		end
		log_state_update(new_state, context)
	end

	run_new_state_user_callbacks(new_state, context)
end

log_state_update = function(new_state, context)
	if context.error then
		MPAPI.sendWarnMessage('Connection error: ' .. tostring(context.error))
	elseif new_state == 'connected' then
		MPAPI.sendDebugMessage('Connected! Player ID: ' .. tostring(_connection.player_id))
	elseif new_state == 'disconnected' then
		MPAPI.sendDebugMessage('Disconnected from server')
	end
end

reset_connection_state_variables = function()
	MPAPI.connection_state.player_id = ''
	MPAPI.connection_state.steam_name = ''
	MPAPI.connection_state.discord_name = ''
	MPAPI.connection_state.is_temp = false
	MPAPI.connection_state.use_discord_name = false
	MPAPI.connection_state.preferred_joker = 'j_joker'
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
