--[[
    Balatro Multiplayer MQTT Client

    A wrapper around luamqtt with OpenSSL TLS support designed for
    integration with Balatro's networking layer.

    luamqtt runs on a dedicated love.thread and communicates with the
    main thread via Love2D channels.
]]

local mqtt_client = {}

-- Separator for channel messages (SOH — won't appear in topics/JSON)
local SEP = '\1'

-- Default configuration
local DEFAULT_CONFIG = {
	broker = 'balatro.virtualized.dev',
	port = 8883,
	secure = true,
	client_id = nil, -- Auto-generated if nil
	clean = true,
	keep_alive = 60,
	reconnect = false,
	verify = false,
	username = nil, -- MQTT username (player ID for auth)
	password = nil, -- MQTT password (JWT token for auth)
}

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
		config.client_id = 'balatro_' .. tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999))
	end

	local self = {
		config = config,
		connected = false,
		subscriptions = {}, -- topic -> qos
		message_handlers = {}, -- topic pattern -> handler fn
		on_connect = nil,
		on_disconnect = nil,
		on_error = nil,
		on_http_response = nil,
		on_http_error = nil,
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

	local lua_pattern = pattern:gsub('([%.%-%[%]%(%)%$%^])', '%%%1'):gsub('%+', '[^/]+'):gsub('#', '.*')

	return topic:match('^' .. lua_pattern .. '$') ~= nil
end

----------------------------------------------------------------------
-- Convenience method for Balatro Multiplayer topic structure
----------------------------------------------------------------------

function mqtt_client:lobby_topic(lobby_code, subtopic)
	if subtopic then
		return string.format('lobby/%s/%s', lobby_code, subtopic)
	else
		return string.format('lobby/%s', lobby_code)
	end
end

----------------------------------------------------------------------
-- Start the network thread (without connecting to a broker)
----------------------------------------------------------------------

function mqtt_client:start_thread()
	if self.thread then
		return true
	end

	-- Create channels (unnamed — safe for multiple instances)
	self.tx_channel = love.thread.newChannel()
	self.rx_channel = love.thread.newChannel()

	-- Load thread code from file via NFS (Love2D sandbox can't see mod dirs)
	local thread_path = MPAPI.path .. 'networking/mqtt_thread.lua'
	local file_content = assert(NFS.read(thread_path), 'Failed to read ' .. thread_path)
	local file_data = love.filesystem.newFileData(file_content, 'mqtt_thread.lua')
	self.thread = love.thread.newThread(file_data)
	self.thread:start(self.tx_channel, self.rx_channel)

	-- Send setup message with package paths
	local setup_msg = 'setup' .. SEP .. (package.path or '') .. SEP .. (package.cpath or '')
	self.tx_channel:push(setup_msg)

	-- The background thread's own require('mqtt')/require('openssl_ffi')
	-- can't actually resolve those files when this mod is deployed as a
	-- zip (the common case - see lib/thread_preload.lua for the full
	-- root-cause writeup): package.path's entries point into Steamodded's
	-- virtual zip mount, which only the main thread's require() can read
	-- through. Pre-read the actual source here (this thread's NFS.read()
	-- works fine) and hand it over the channel so mqtt_thread.lua can
	-- register it into its own package.preload before requiring it.
	--
	-- Loaded via MPAPI.load_mpapi_file (not require) for the same reason
	-- e72d5c4 fixed lib/debugplus/console.lua and ui.lua: on the MAIN
	-- thread, require() is resolved by Lua's stock package.path searcher,
	-- which just can't read through a zip Steamodded has mounted via
	-- LÖVE's PhysFS-backed virtual filesystem at all - confirmed live,
	-- this require('thread_preload') failed with "not found" even with a
	-- correct package.path and a non-dotted (so not e72d5c4's backslash-
	-- substitution case) module name. NFS.read() (via MPAPI.load_mpapi_file
	-- -> SMODS.load_file) is the one file-loading path proven to work
	-- whether the mod is a folder or a zip.
	local thread_preload = MPAPI.load_mpapi_file('lib/thread_preload.lua')
	local preload = thread_preload.build_preload_table('lib/mqtt', 'mqtt')
	for name, source in pairs(thread_preload.read_single_module('networking/openssl_ffi.lua', 'openssl_ffi')) do
		preload[name] = source
	end
	self.tx_channel:push(preload)

	return true
end

----------------------------------------------------------------------
-- Connect to the MQTT broker (spawns network thread if needed)
----------------------------------------------------------------------

function mqtt_client:connect()
	self:start_thread()

	-- Send connect command
	local cfg = self.config
	local connect_msg = table.concat({
		'connect',
		cfg.broker,
		tostring(cfg.port),
		tostring(cfg.secure),
		cfg.client_id,
		tostring(cfg.keep_alive),
		tostring(cfg.verify or false),
		cfg.username or '',
		cfg.password or '',
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
		self.tx_channel:push('subscribe' .. SEP .. topic .. SEP .. tostring(qos))
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
		return false, 'Not connected'
	end

	self.tx_channel:push(table.concat({
		'publish',
		topic,
		payload or '',
		tostring(qos),
		tostring(retain),
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP POST request via the network thread
----------------------------------------------------------------------

function mqtt_client:http_post(url, body)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_post',
		url,
		body or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP POST request with Authorization: Bearer header
----------------------------------------------------------------------

function mqtt_client:http_post_auth(url, body, token)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_post_auth',
		url,
		body or '',
		token or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP PUT request with Authorization: Bearer header
----------------------------------------------------------------------

function mqtt_client:http_put_auth(url, body, token)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_put_auth',
		url,
		body or '',
		token or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP GET request with Authorization: Bearer header
----------------------------------------------------------------------

function mqtt_client:http_get_auth(url, token)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_get_auth',
		url,
		token or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP DELETE request with Authorization: Bearer header
----------------------------------------------------------------------

function mqtt_client:http_delete_auth(url, token)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_delete_auth',
		url,
		token or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Send an HTTP DELETE request with body and Authorization: Bearer header
----------------------------------------------------------------------

function mqtt_client:http_delete_with_body_auth(url, body, token)
	if not self.tx_channel then
		return false, 'Thread not running'
	end

	self.tx_channel:push(table.concat({
		'http_delete_with_body_auth',
		url,
		body or '',
		token or '',
	}, SEP))

	return true
end

----------------------------------------------------------------------
-- Process network events (call from game loop)
----------------------------------------------------------------------

function mqtt_client:update()
	if not self.rx_channel then
		return
	end

	-- Drain all events from the thread
	while true do
		local raw = self.rx_channel:pop()
		if not raw then
			break
		end

		-- Parse event
		local parts = {}
		for part in (raw .. SEP):gmatch('(.-)' .. SEP) do
			parts[#parts + 1] = part
		end

		local event = parts[1]

		if event == 'connected' then
			self.connected = true

			-- Send pending subscriptions
			for topic, qos in pairs(self.subscriptions) do
				self.tx_channel:push('subscribe' .. SEP .. topic .. SEP .. tostring(qos))
			end

			if self.on_connect then
				self.on_connect()
			end
		elseif event == 'message' then
			local topic = parts[2]
			local payload = parts[3]

			for pattern, handler in pairs(self.message_handlers) do
				if self:topic_matches(pattern, topic) then
					handler(topic, payload)
				end
			end
		elseif event == 'error' then
			local msg = parts[2] or 'unknown error'
			if self.on_error then
				self.on_error(msg)
			end
		elseif event == 'disconnected' then
			self.connected = false
			if self.on_disconnect then
				self.on_disconnect()
			end
		elseif event == 'subscribed' then
			-- Could fire a callback here if needed
		elseif event == 'http_response' then
			local status = parts[2]
			local body = parts[3] or ''
			if self.on_http_response then
				self.on_http_response(tonumber(status), body)
			end
		elseif event == 'http_error' then
			local msg = parts[2] or 'HTTP request failed'
			if self.on_http_error then
				self.on_http_error(msg)
			end
		elseif event == 'log' then
			MPAPI.sendDebugMessage(parts[2] or '')
		end
	end

	-- Check thread health
	if self.thread then
		local err = self.thread:getError()
		if err then
			if self.on_error then
				self.on_error('Thread crashed: ' .. tostring(err))
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
		self.tx_channel:push('disconnect')
		self.tx_channel:push('shutdown')
	end
	self.connected = false

	-- Block until the background thread actually processes 'shutdown' and its
	-- loop returns, instead of just queuing the message and moving on. Without
	-- this, a quick disconnect()-then-connect() (e.g. MPAPI.reconnect()) spawns
	-- a brand new thread while the old one is still winding down its own
	-- socket/TLS teardown -- multiple threads independently driving luamqtt +
	-- the OpenSSL FFI bridge at once, confirmed live via mqtt_thread.lua diag
	-- logging (concurrent 'connect' handlers firing on different threads
	-- within the same reconnect burst). Thread:wait() is a no-op if the thread
	-- already finished, so this is safe to call unconditionally. Usually
	-- resolves in well under 100ms (bounded by _sync_iteration's 0.05s socket
	-- timeout); can take longer if the thread is mid-retry on an HTTP request
	-- (request_with_retry's backoff sleeps run on the same thread), but
	-- disconnect/reconnect isn't a hot path so that's an acceptable trade-off
	-- against leaking/duplicating connections.
	if self.thread then
		self.thread:wait()
		self.thread = nil
	end
end

MPAPI.networking.mqtt_client = mqtt_client
