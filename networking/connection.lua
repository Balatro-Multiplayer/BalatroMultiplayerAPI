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
        token_store = opts.token_store,
        config = opts.config or {},
        state = STATES.DISCONNECTED,

        player_id = nil,
        jwt_token = nil,
        username = nil,
        steam_id = nil,
        discord_name = nil,
        is_temp = false,
        auth_ticket_handle = nil,

        lobby_data = nil,
        on_state_change = nil,
    }

    setmetatable(self, { __index = connection })
    return self
end

function connection:get_state()
    return self.state
end

local function fire(self, new_state, context)
    if self.on_state_change then
        local ok, err = pcall(self.on_state_change, new_state, context)
        if not ok then
            MPAPI.sendWarnMessage("on_state_change error: " .. tostring(err))
        end
    end
end

local function set_state(self, new_state, context)
    local old = self.state
    self.state = new_state
    fire(self, new_state, context or {old_state = old})
end

-- Shared handler for successful auth (Steam, refresh token, or dev)
function connection:_handle_auth_success(data)
    self.jwt_token = data.token
    self.player_id = data.player and data.player.id or nil
    self.is_temp = data.player and data.player.isTemp or false
    if data.player and data.player.username then
        self.username = data.player.username
    end
    if data.player and data.player.discordUsername then
        self.discord_name = data.player.discordUsername
    end

    self.lobby_data = data.lobby or nil

    if not self.player_id or not self.jwt_token then
        set_state(self, STATES.DISCONNECTED, {error = "Auth response missing player ID or token"})
        return
    end

    -- Save refresh token for next launch
    if data.refreshToken and self.token_store then
        self.token_store.save(data.refreshToken)
    end

    self:_mqtt_connect_with_credentials()
end

-- Try Steam auth first
function connection:_try_steam_auth()
    if not self.steam or not self.steam.available() then
        self:_try_refresh_auth("Steam is not available")
        return
    end

    local ticket_data, ticket_err = self.steam.get_auth_ticket()
    if not ticket_data then
        self:_try_refresh_auth("Steam ticket failed: " .. tostring(ticket_err))
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
            self:_try_refresh_auth("Steam auth failed: " .. tostring(err))
            return
        end

        self:_handle_auth_success(data)
    end)
end

-- Fallback: try refresh token auth
function connection:_try_refresh_auth(steam_error)
    if not self.token_store then
        set_state(self, STATES.DISCONNECTED, {error = steam_error or "No auth method available"})
        return
    end

    local refresh_token = self.token_store.load()
    if not refresh_token then
        set_state(self, STATES.DISCONNECTED, {error = steam_error or "No saved credentials"})
        return
    end

    local username = self.username or "Player"
    self.mqtt:start_thread()

    self.api:authenticate_refresh(refresh_token, username, function(err, data)
        if err then
            -- Refresh token failed, clear it
            self.token_store.clear()
            set_state(self, STATES.DISCONNECTED, {error = steam_error or ("Refresh auth failed: " .. tostring(err))})
            return
        end

        self:_handle_auth_success(data)
    end)
end

function connection:connect()
    if self.state ~= STATES.DISCONNECTED then
        fire(self, self.state, {error = "Already " .. self.state})
        return
    end

    set_state(self, STATES.AUTHENTICATING)
    self:_try_steam_auth()
end

function connection:_mqtt_connect_with_credentials()
    set_state(self, STATES.CONNECTING)

    local SEP = "\1"
    local cfg = self.config

    self.mqtt.on_connect = function()
        set_state(self, STATES.CONNECTED)

        -- Fire reconnect event if returning to an existing lobby
        if self.lobby_data then
            fire(self, STATES.CONNECTED, { reconnected_lobby = self.lobby_data })
            self.lobby_data = nil
        end

        -- Subscribe to player notification topics
        if self.player_id then
            local topic = "player/" .. self.player_id .. "/account/#"
            MPAPI.sendDebugMessage("Subscribing to " .. topic)
            self.mqtt:subscribe(topic, 1, function(t, payload)
                self:_handle_player_notification(t, payload)
            end)
        end
    end

    self.mqtt.on_error = function(msg)
        if self.state == STATES.CONNECTING then
            set_state(self, STATES.DISCONNECTED, {error = "MQTT connection failed: " .. tostring(msg)})
        else
            fire(self, self.state, {error = tostring(msg)})
        end
    end

    self.mqtt.on_disconnect = function()
        set_state(self, STATES.DISCONNECTED)
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

function connection:_handle_player_notification(topic, payload)
    local subtopic = topic:match("^player/[^/]+/account/(.+)$")
    if not subtopic then return end

    MPAPI.sendDebugMessage("Player notification: " .. subtopic .. " payload=" .. tostring(payload))

    if subtopic == "discord_linked" then
        local ok, data = pcall(function()
            if json and json.decode then
                return json.decode(payload)
            end
            local j = require("json")
            return j.decode(payload)
        end)
        if ok and data then
            self.discord_name = data.username or "Linked"
            MPAPI.sendDebugMessage("Discord linked, set discord_name=" .. tostring(self.discord_name))
            fire(self, self.state, {player_update = true})
        else
            MPAPI.sendWarnMessage("discord_linked: failed to parse payload, ok=" .. tostring(ok))
        end
    end
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

    set_state(self, STATES.DISCONNECTED)
    self.player_id = nil
    self.jwt_token = nil
    self.lobby_data = nil
end

return connection
