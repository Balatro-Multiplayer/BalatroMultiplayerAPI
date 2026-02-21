--[[
    Balatro Multiplayer MQTT Client

    A wrapper around luamqtt with OpenSSL TLS support designed for
    integration with Balatro's networking layer.

    luamqtt runs on a dedicated love.thread and communicates with the
    main thread via Love2D channels.
]]

local mqtt_client = {}

-- Separator for channel messages (SOH — won't appear in topics/JSON)
local SEP = "\1"

-- Default configuration
local DEFAULT_CONFIG = {
    broker = "broker.hivemq.com",
    port = 1883,           -- Non-TLS default, 8883 for TLS
    secure = false,
    client_id = nil,       -- Auto-generated if nil
    clean = true,
    keep_alive = 60,
    reconnect = false,
    verify = false,
}

----------------------------------------------------------------------
-- Thread code (embedded as a string, passed to love.thread.newThread)
----------------------------------------------------------------------

local THREAD_CODE = [==[
-- MQTT network thread
-- Receives commands on tx_channel, sends events on rx_channel.
-- luamqtt runs in natural blocking sync mode with moderate timeout.

local tx_channel, rx_channel = ...  -- passed from main thread

-- Read setup message: package paths
local setup = tx_channel:demand()  -- blocks until available
local pkg_path, pkg_cpath = setup:match("^setup\1(.*)\1(.*)$")
if pkg_path then package.path = pkg_path end
if pkg_cpath then package.cpath = pkg_cpath end

local SEP = "\1"
local socket = require("socket")
local mqtt = require("mqtt")

-- Optionally load OpenSSL connector
local openssl_connector
pcall(function()
    require("openssl_ffi")
    openssl_connector = require("mqtt.openssl_connector")
end)

local client = nil       -- luamqtt client instance
local connected = false
local running = true

-- Push an event to the main thread
local function push_event(...)
    local parts = {...}
    rx_channel:push(table.concat(parts, SEP))
end

-- Monkey-patch _receive_packet on a client so that timeout errors
-- return the string "timeout" instead of (false, "...timeout..."),
-- which _io_iteration handles gracefully.
local function patch_receive_packet(cl)
    local mt = getmetatable(cl)
    local orig = mt.__index._receive_packet
    cl._receive_packet = function(self)
        local packet, err = orig(self)
        if packet == false and err and err:find("timeout") then
            return "timeout"
        end
        return packet, err
    end
end

-- Set up luamqtt event handlers that push events to rx_channel
local function setup_handlers(cl)
    cl:on{
        connect = function(connack)
            if connack.rc ~= 0 then
                connected = false
                push_event("error", "Connection failed: " .. tostring(connack:reason_string()))
                return
            end
            connected = true
            push_event("connected")
        end,

        message = function(msg)
            cl:acknowledge(msg)
            push_event("message", msg.topic, msg.payload)
        end,

        subscribe = function()
            -- SUBACK received; we don't track per-topic here
        end,

        error = function(err)
            push_event("error", tostring(err))
        end,

        close = function()
            connected = false
            push_event("disconnected")
        end,
    }
end

-- Handle a connect command
local function handle_connect(broker, port, secure, client_id, keep_alive, verify)
    if client then
        pcall(function() client:disconnect() end)
        client = nil
        connected = false
    end

    local uri = broker .. ":" .. port
    local client_opts = {
        uri = uri,
        id = client_id,
        clean = true,
        keep_alive = tonumber(keep_alive) or 60,
    }

    if secure == "true" then
        if openssl_connector then
            client_opts.connector = openssl_connector
            client_opts.secure = true
        else
            client_opts.secure = true
        end
    end

    local cl = mqtt.client(client_opts)
    setup_handlers(cl)
    client = cl

    local ok, err = cl:start_connecting()
    if not ok then
        push_event("error", "Connect failed: " .. tostring(err))
        client = nil
        return
    end

    -- Set a moderate timeout so _sync_iteration blocks briefly then
    -- returns, giving us a chance to check for new commands.
    local conn = cl.connection
    if conn and cl.args.connector then
        cl.args.connector.settimeout(conn, 0.05)
    end

    -- Patch _receive_packet so timeout is non-fatal
    patch_receive_packet(cl)
end

-- Handle a subscribe command
local function handle_subscribe(topic, qos)
    if not client or not connected then return end
    client:subscribe{ topic = topic, qos = tonumber(qos) or 1 }
    push_event("subscribed", topic)
end

-- Handle a publish command
local function handle_publish(topic, payload, qos, retain)
    if not client or not connected then return end
    client:publish{
        topic = topic,
        payload = payload,
        qos = tonumber(qos) or 1,
        retain = (retain == "true"),
    }
end

-- Handle a disconnect command
local function handle_disconnect()
    if client then
        pcall(function() client:disconnect() end)
        connected = false
        client = nil
    end
end

-- Parse and dispatch a command string
local function dispatch_command(cmd)
    local parts = {}
    for part in (cmd .. SEP):gmatch("(.-)" .. SEP) do
        parts[#parts + 1] = part
    end

    local action = parts[1]
    if action == "connect" then
        handle_connect(parts[2], parts[3], parts[4], parts[5], parts[6], parts[7])
    elseif action == "subscribe" then
        handle_subscribe(parts[2], parts[3])
    elseif action == "publish" then
        handle_publish(parts[2], parts[3], parts[4], parts[5])
    elseif action == "disconnect" then
        handle_disconnect()
    elseif action == "shutdown" then
        handle_disconnect()
        running = false
    end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
while running do
    -- 1. Drain all pending commands (non-blocking)
    while true do
        local cmd = tx_channel:pop()
        if not cmd then break end
        dispatch_command(cmd)
        if not running then break end
    end

    if not running then break end

    -- 2. Drive MQTT I/O
    if client and client.connection then
        local ok, err = pcall(function()
            client:_sync_iteration()
        end)
        -- On iteration error, report
        if not ok and err then
            push_event("error", tostring(err))
        end
    else
        -- No active connection
        love.timer.sleep(0.01)
    end
end
]==]

----------------------------------------------------------------------
-- Create a new MQTT client
----------------------------------------------------------------------

function mqtt_client.new(config)
    config = config or {}

    -- Merge with defaults
    for k, v in pairs(DEFAULT_CONFIG) do
        if config[k] == nil then
            config[k] = v
        end
    end

    -- Generate client ID if not provided
    if not config.client_id then
        config.client_id = "balatro_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    end

    local self = {
        config = config,
        connected = false,
        subscriptions = {},      -- topic -> qos
        message_handlers = {},   -- topic pattern -> handler fn
        on_connect = nil,
        on_disconnect = nil,
        on_error = nil,
        -- Thread state
        thread = nil,
        tx_channel = nil,
        rx_channel = nil,
    }

    setmetatable(self, { __index = mqtt_client })
    return self
end

----------------------------------------------------------------------
-- Check if topic matches pattern (supports + and # wildcards)
----------------------------------------------------------------------

function mqtt_client:topic_matches(pattern, topic)
    if pattern == topic then
        return true
    end

    local lua_pattern = pattern
        :gsub("([%.%-%[%]%(%)%$%^])", "%%%1")
        :gsub("%+", "[^/]+")
        :gsub("#", ".*")

    return topic:match("^" .. lua_pattern .. "$") ~= nil
end

----------------------------------------------------------------------
-- Convenience method for Balatro Multiplayer topic structure
----------------------------------------------------------------------

function mqtt_client:lobby_topic(lobby_code, subtopic)
    if subtopic then
        return string.format("balatro/lobbies/%s/%s", lobby_code, subtopic)
    else
        return string.format("balatro/lobbies/%s", lobby_code)
    end
end

----------------------------------------------------------------------
-- Connect to the MQTT broker (spawns network thread)
----------------------------------------------------------------------

function mqtt_client:connect()
    -- Create channels (unnamed — safe for multiple instances)
    self.tx_channel = love.thread.newChannel()
    self.rx_channel = love.thread.newChannel()

    -- Spawn thread
    self.thread = love.thread.newThread(THREAD_CODE)
    self.thread:start(self.tx_channel, self.rx_channel)

    -- Send setup message with package paths
    local setup_msg = "setup" .. SEP .. (package.path or "") .. SEP .. (package.cpath or "")
    self.tx_channel:push(setup_msg)

    -- Send connect command
    local cfg = self.config
    local connect_msg = table.concat({
        "connect",
        cfg.broker,
        tostring(cfg.port),
        tostring(cfg.secure),
        cfg.client_id,
        tostring(cfg.keep_alive),
        tostring(cfg.verify or false),
    }, SEP)
    self.tx_channel:push(connect_msg)

    return true
end

----------------------------------------------------------------------
-- Subscribe to a topic
----------------------------------------------------------------------

function mqtt_client:subscribe(topic, qos, handler)
    qos = qos or 1
    self.subscriptions[topic] = qos

    if handler then
        self.message_handlers[topic] = handler
    end

    if self.connected and self.tx_channel then
        self.tx_channel:push("subscribe" .. SEP .. topic .. SEP .. tostring(qos))
    end
end

----------------------------------------------------------------------
-- Unsubscribe from a topic
----------------------------------------------------------------------

function mqtt_client:unsubscribe(topic)
    self.subscriptions[topic] = nil
    self.message_handlers[topic] = nil
end

----------------------------------------------------------------------
-- Publish a message
----------------------------------------------------------------------

function mqtt_client:publish(topic, payload, qos, retain)
    qos = qos or 1
    retain = retain or false

    if not self.tx_channel then
        return false, "Not connected"
    end

    self.tx_channel:push(table.concat({
        "publish",
        topic,
        payload or "",
        tostring(qos),
        tostring(retain),
    }, SEP))

    return true
end

----------------------------------------------------------------------
-- Process network events (call from game loop)
----------------------------------------------------------------------

function mqtt_client:update()
    if not self.rx_channel then return end

    -- Drain all events from the thread
    while true do
        local raw = self.rx_channel:pop()
        if not raw then break end

        -- Parse event
        local parts = {}
        for part in (raw .. SEP):gmatch("(.-)" .. SEP) do
            parts[#parts + 1] = part
        end

        local event = parts[1]

        if event == "connected" then
            self.connected = true

            -- Send pending subscriptions
            for topic, qos in pairs(self.subscriptions) do
                self.tx_channel:push("subscribe" .. SEP .. topic .. SEP .. tostring(qos))
            end

            if self.on_connect then
                self.on_connect()
            end

        elseif event == "message" then
            local topic = parts[2]
            local payload = parts[3]

            for pattern, handler in pairs(self.message_handlers) do
                if self:topic_matches(pattern, topic) then
                    handler(topic, payload)
                end
            end

        elseif event == "error" then
            local msg = parts[2] or "unknown error"
            if self.on_error then
                self.on_error(msg)
            end

        elseif event == "disconnected" then
            self.connected = false
            if self.on_disconnect then
                self.on_disconnect()
            end

        elseif event == "subscribed" then
            -- Could fire a callback here if needed
        end
    end

    -- Check thread health
    if self.thread then
        local err = self.thread:getError()
        if err then
            if self.on_error then
                self.on_error("Thread crashed: " .. tostring(err))
            end
            self.connected = false
            self.thread = nil
        end
    end
end

----------------------------------------------------------------------
-- Disconnect from the broker
----------------------------------------------------------------------

function mqtt_client:disconnect()
    if self.tx_channel then
        self.tx_channel:push("disconnect")
        self.tx_channel:push("shutdown")
    end
    self.connected = false
end

return mqtt_client
