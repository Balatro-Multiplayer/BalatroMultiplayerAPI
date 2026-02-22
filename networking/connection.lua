local connection = {}

local STATES = {
    DISCONNECTED  = "disconnected",
    AUTHENTICATING = "authenticating",
    CONNECTING    = "connecting",
    CONNECTED     = "connected",
}

function connection.new(opts)
    local self = {
        mqtt = opts.mqtt_client,
        api = opts.api_client,
        steam = opts.steam,
        config = opts.config or {},

        state = STATES.DISCONNECTED,

        player_id = nil,
        jwt_token = nil,
        username = nil,
        steam_id = nil,
        auth_ticket_handle = nil,

        on_connected = nil,
        on_error = nil,
        on_disconnected = nil,
    }

    setmetatable(self, { __index = connection })
    return self
end

function connection:get_state()
    return self.state
end

local function fire(self, name, ...)
    local cb = self[name]
    if cb then
        local ok, err = pcall(cb, ...)
        if not ok then
            if name ~= "on_error" and self.on_error then
                pcall(self.on_error, "Callback error in " .. name .. ": " .. tostring(err))
            end
        end
    end
end

function connection:connect()
    if self.state ~= STATES.DISCONNECTED then
        fire(self, "on_error", "Already " .. self.state)
        return
    end

    self.state = STATES.AUTHENTICATING

    if not self.steam or not self.steam.available() then
        self.state = STATES.DISCONNECTED
        fire(self, "on_error", "Steam is not available")
        return
    end

    local ticket_data, ticket_err = self.steam.get_auth_ticket()
    if not ticket_data then
        self.state = STATES.DISCONNECTED
        fire(self, "on_error", "Steam ticket failed: " .. tostring(ticket_err))
        return
    end

    self.auth_ticket_handle = ticket_data.handle
    self.steam_id = self.steam.get_steam_id()
    self.username = self.steam.get_persona_name() or "Player"

    self.mqtt:start_thread()

    self.api:authenticate_steam(ticket_data.ticket, self.username, function(err, data)
        if self.auth_ticket_handle then
            self.steam.cancel_auth_ticket(self.auth_ticket_handle)
            self.auth_ticket_handle = nil
        end

        if err then
            self.state = STATES.DISCONNECTED
            fire(self, "on_error", "Auth failed: " .. tostring(err))
            return
        end

        self.jwt_token = data.token
        self.player_id = data.player and data.player.id or nil
        if data.player and data.player.username then
            self.username = data.player.username
        end

        if not self.player_id or not self.jwt_token then
            self.state = STATES.DISCONNECTED
            fire(self, "on_error", "Auth response missing player ID or token")
            return
        end

        self:_mqtt_connect_with_credentials()
    end)
end

function connection:_mqtt_connect_with_credentials()
    self.state = STATES.CONNECTING

    local SEP = "\1"
    local cfg = self.config

    self.mqtt.on_connect = function()
        self.state = STATES.CONNECTED
        fire(self, "on_connected")
    end

    self.mqtt.on_error = function(msg)
        if self.state == STATES.CONNECTING then
            self.state = STATES.DISCONNECTED
            fire(self, "on_error", "MQTT connection failed: " .. tostring(msg))
        else
            fire(self, "on_error", tostring(msg))
        end
    end

    self.mqtt.on_disconnect = function()
        local was_connected = (self.state == STATES.CONNECTED)
        self.state = STATES.DISCONNECTED
        if was_connected then
            fire(self, "on_disconnected")
        end
    end

    local connect_msg = table.concat({
        "connect",
        cfg.mqtt_broker or "localhost",
        tostring(cfg.mqtt_port or 1883),
        tostring(cfg.mqtt_secure or false),
        self.player_id,
        tostring(cfg.mqtt_keep_alive or 60),
        tostring(cfg.mqtt_secure and cfg.mqtt_verify or false),
        self.player_id,
        self.jwt_token,
    }, SEP)

    self.mqtt.tx_channel:push(connect_msg)
end

function connection:disconnect()
    if self.state == STATES.DISCONNECTED then return end

    if self.auth_ticket_handle and self.steam then
        self.steam.cancel_auth_ticket(self.auth_ticket_handle)
        self.auth_ticket_handle = nil
    end

    if self.mqtt then
        self.mqtt:disconnect()
    end

    self.state = STATES.DISCONNECTED
    self.player_id = nil
    self.jwt_token = nil
end

return connection
