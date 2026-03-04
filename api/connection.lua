MPAPI.connection_state = {
    state = "disconnected",
    status_text = localize('k_status_offline'),
    player_id = "",
    display_name = localize('b_retry_connection'),
    steam_name = "",
    discord_name = "",
    discord_id = "",
    is_temp = false,
}

local _mqtt_instance = nil
local _connection = nil
local _ready = false
local _ready_callbacks = {}
local _last_opts = nil

-- Production server defaults
local DEFAULTS = {
    api_url     = "https://balatro.virtualized.dev",
    mqtt_broker = "balatro.virtualized.dev",
    mqtt_port   = 8883,
    mqtt_secure = true,
}

function MPAPI.connect(opts)
    opts = opts or {}
    _last_opts = opts

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
    local mqtt_secure = DEFAULTS.mqtt_secure
    if opts.mqtt_secure ~= nil then mqtt_secure = opts.mqtt_secure end

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
        token_store = MPAPI.modules.token_store,
        config = {
            mqtt_broker = mqtt_broker,
            mqtt_port   = mqtt_port,
            mqtt_secure = mqtt_secure,
        },
    })

    local cs = MPAPI.connection_state

    _connection.on_state_change = function(new_state, context)
        context = context or {}

        -- Update connection_state
        cs.state = new_state
        if new_state == "connected" then
            cs.status_text = localize('k_status_connected')
            cs.player_id = _connection.player_id or ""
            cs.steam_name = MPAPI.truncate(_connection.username or "", 20)
            cs.discord_name = MPAPI.truncate(_connection.discord_name or "", 20)
            cs.is_temp = _connection.is_temp or false
        else
            if new_state == "authenticating" then
                cs.status_text = localize('k_status_signing_in')
            elseif new_state == "connecting" then
                cs.status_text = localize('k_status_connecting')
            else
                cs.status_text = localize('k_status_offline')
            end
            cs.player_id = ""
            cs.steam_name = ""
            cs.discord_name = ""
            cs.is_temp = false
        end
        cs.display_name = (cs.discord_name ~= "" and cs.discord_name) or (cs.steam_name ~= "" and cs.steam_name) or "Retry Connection"

        -- Player data update (e.g. discord linked)
        if context.player_update then
            cs.discord_name = MPAPI.truncate(_connection.discord_name or "", 20)
        end

        -- Logging
        if context.error then
            MPAPI.sendWarnMessage("Connection error: " .. tostring(context.error))
        elseif new_state == "connected" then
            MPAPI.sendDebugMessage("Connected! Player ID: " .. tostring(_connection.player_id))
        elseif new_state == "disconnected" and context.old_state == "connected" then
            MPAPI.sendDebugMessage("Disconnected from server")
        end

        -- User callbacks
        if context.error and opts.on_error then
            opts.on_error(context.error)
        elseif new_state == "connected" and context.reconnected_lobby and opts.on_reconnected then
            opts.on_reconnected(_connection, context.reconnected_lobby)
        elseif new_state == "connected" and opts.on_connected then
            opts.on_connected(_connection)
        elseif new_state == "disconnected" and context.old_state == "connected" and opts.on_disconnected then
            opts.on_disconnected()
        end

        -- UI refresh
        if MPAPI.account_button then
            MPAPI.account_button:update()
            MPAPI.account_overlay:update()
        end
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
    local cs = MPAPI.connection_state
    cs.state = "disconnected"
    cs.status_text = "Offline"
    cs.player_id = ""
    cs.steam_name = ""
    cs.discord_name = ""
    cs.is_temp = false
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

function MPAPI.get_last_opts()
    return _last_opts
end

function MPAPI.update()
    if _mqtt_instance then
        _mqtt_instance:update()
    end
end

function MPAPI.get_discord_link_url(callback)
    local conn = _connection
    if not conn or conn:get_state() ~= "connected" then
        callback("Not connected", nil)
        return
    end
    if not conn.jwt_token then
        callback("No JWT token", nil)
        return
    end
    conn.api:get_discord_link_url(conn.jwt_token, callback)
end

function MPAPI.on_loaded(fn)
    if _ready then
        fn()
    else
        _ready_callbacks[#_ready_callbacks + 1] = fn
    end
end

function MPAPI.is_ready()
    return _ready
end

G.E_MANAGER:add_event(Event({
    blockable = false,
    blocking = false,
    func = function()
        if not G.STEAM then
            return false
        end
        _ready = true
        for _, fn in ipairs(_ready_callbacks) do
            local ok, err = pcall(fn)
            if not ok then
                MPAPI.sendWarnMessage("on_loaded callback error: " .. tostring(err))
            end
        end
        _ready_callbacks = {}
        return true
    end,
}))
