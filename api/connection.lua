local _mqtt_instance = nil
local _connection = nil

-- Production server defaults
local DEFAULTS = {
    api_url     = "https://balatro.virtualized.dev",
    mqtt_broker = "balatro.virtualized.dev",
    mqtt_port   = 8883,
    mqtt_secure = true,
}

function MPAPI.connect(opts)
    opts = opts or {}

    if _connection and _connection:get_state() ~= "disconnected" then
        MPAPI.sendWarnMessage("Already connected or connecting")
        return
    end

    if not MPAPI.modules.mqtt_client then
        MPAPI.sendWarnMessage("MQTT client module not available")
        return
    end

    -- Mod-provided overrides take precedence over defaults
    local api_url     = opts.api_url     or DEFAULTS.api_url
    local mqtt_broker = opts.mqtt_broker  or DEFAULTS.mqtt_broker
    local mqtt_port   = opts.mqtt_port    or DEFAULTS.mqtt_port
    local mqtt_secure = opts.mqtt_secure ~= nil and opts.mqtt_secure or DEFAULTS.mqtt_secure

    _mqtt_instance = MPAPI.modules.mqtt_client.new({
        broker = mqtt_broker,
        port = mqtt_port,
        secure = mqtt_secure,
    })

    local api = MPAPI.modules.api_client.new(_mqtt_instance, api_url)

    _connection = MPAPI.modules.connection.new({
        mqtt_client = _mqtt_instance,
        api_client = api,
        steam = MPAPI.modules.steam,
        config = {
            mqtt_broker = mqtt_broker,
            mqtt_port   = mqtt_port,
            mqtt_secure = mqtt_secure,
        },
    })

    _connection.on_connected = function()
        MPAPI.sendDebugMessage("Connected! Player ID: " .. tostring(_connection.player_id))
        if opts.on_connected then opts.on_connected(_connection) end
    end

    _connection.on_error = function(msg)
        MPAPI.sendWarnMessage("Connection error: " .. tostring(msg))
        if opts.on_error then opts.on_error(msg) end
    end

    _connection.on_disconnected = function()
        MPAPI.sendDebugMessage("Disconnected from server")
        if opts.on_disconnected then opts.on_disconnected() end
    end

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
end

function MPAPI.is_connected()
    if _connection then
        return _connection:get_state()
    end
    return "disconnected"
end

function MPAPI.get_mqtt()
    return _mqtt_instance
end

function MPAPI.get_connection()
    return _connection
end
