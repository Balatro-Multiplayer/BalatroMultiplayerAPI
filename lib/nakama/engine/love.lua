--[[
    LÖVE engine for the vendored Nakama SDK - the counterpart of upstream's
    nakama/engine/defold.lua (not vendored), implementing the same six
    functions with the same callback contract:

      uuid, http, socket_create, socket_connect, socket_disconnect, socket_send

    Network I/O runs on love.threads:
      - networking/nakama_http_thread.lua: one shared thread, one attempt per
        request.
      - networking/nakama_ws_thread.lua: one thread per connected socket
        (RFC 6455 client in networking/websocket.lua).

    Nothing is delivered until M.update() runs: it drains the threads,
    fires due retries (Defold's timer.delay) and calls the SDK callbacks on
    the main thread. Whoever wires this up must call it every frame, as
    MPAPI.update does (api/connection/lifecycle.lua).

    Main-thread only. Load it through networking/nakama_sdk.lua, which
    registers the SDK's modules first.
]]

local json = require('nakama.util.json')
local b64 = require('nakama.util.b64')
local uri = require('nakama.util.uri')
local log = require('nakama.util.log')

local b64_encode = b64.encode
local uri_encode_component = uri.encode_component

local M = {}

local SEP = '\1'

local http_worker = nil -- { thread, tx, rx }
local pending_http = {} -- request id -> on_response(status, body)
local next_request_id = 0
local timers = {} -- { at, fn }, fired by update()
local socket_workers = {} -- { socket, worker } per connect, until its thread is done

----------------------------------------------------------------------
-- Threads
----------------------------------------------------------------------

-- Pre-read sources for the modules the I/O threads require (see
-- lib/thread_preload.lua for why threads can't require() from the mod).
local function thread_modules()
	local thread_preload = MPAPI.load_mpapi_file('lib/thread_preload.lua')
	local modules = {}
	for _, entry in ipairs({
		{ 'networking/openssl_ffi.lua', 'openssl_ffi' },
		{ 'networking/nakama_net.lua', 'nakama_net' },
		{ 'networking/websocket.lua', 'websocket' },
	}) do
		for name, source in pairs(thread_preload.read_single_module(entry[1], entry[2])) do
			modules[name] = source
		end
	end
	return modules
end

local function start_thread(file_name)
	local path = MPAPI.path .. 'networking/' .. file_name
	local source = assert(NFS.read(path), 'Failed to read ' .. path)
	local worker = {
		thread = love.thread.newThread(love.filesystem.newFileData(source, file_name)),
		tx = love.thread.newChannel(),
		rx = love.thread.newChannel(),
	}
	worker.thread:start(worker.tx, worker.rx)
	worker.tx:push('setup' .. SEP .. package.path .. SEP .. package.cpath)
	worker.tx:push(thread_modules())
	return worker
end

local function after(seconds, fn)
	timers[#timers + 1] = { at = love.timer.getTime() + seconds, fn = fn }
end

----------------------------------------------------------------------
-- UUID
----------------------------------------------------------------------

-- A private generator: seeding the shared math.random (what upstream's
-- nakama.util.uuid does) would disturb anything else drawing from it.
local uuid_rng = nil

--- Returns a random (version 4) UUID string.
function M.uuid()
	if not uuid_rng then
		uuid_rng = love.math.newRandomGenerator(os.time(), math.floor(love.timer.getTime() * 1e6) % 2 ^ 31)
	end
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = uuid_rng:random(0, 255)
	end
	bytes[7] = 0x40 + bytes[7] % 16 -- version 4
	bytes[9] = 0x80 + bytes[9] % 64 -- RFC 4122 variant
	local hex = {}
	for i = 1, 16 do
		hex[i] = ('%02x'):format(bytes[i])
	end
	local s = table.concat(hex)
	return ('%s-%s-%s-%s-%s'):format(s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

----------------------------------------------------------------------
-- HTTP
----------------------------------------------------------------------

local function send_http(url, method, headers, post_data, options, on_response)
	if not http_worker then
		http_worker = start_thread('nakama_http_thread.lua')
	end
	next_request_id = next_request_id + 1
	pending_http[next_request_id] = on_response

	local header_lines = {}
	for name, value in pairs(headers) do
		header_lines[#header_lines + 1] = name .. ': ' .. value
	end
	http_worker.tx:push({
		id = next_request_id,
		method = method,
		url = url,
		headers = table.concat(header_lines, '\n'),
		body = post_data,
		timeout = options.timeout,
	})
end

-- Mirrors defold.lua's make_http_request: decode, retry on failure per
-- retry_intervals, then report { error, message, code }. A transport
-- failure arrives as status 0 with an empty body, like Defold's.
local make_http_request
make_http_request = function(url, method, callback, headers, post_data, options, retry_intervals, retry_count, cancellation_token)
	if cancellation_token and cancellation_token.cancelled then
		callback(nil)
		return
	end
	send_http(url, method, headers, post_data, options, function(status, response)
		if cancellation_token and cancellation_token.cancelled then
			callback(nil)
			return
		end
		log(response)
		local ok, decoded = pcall(json.decode, response)
		-- return result if everything is ok
		if ok and status >= 200 and status <= 299 then
			callback(decoded)
			return
		end

		-- return the error if there are no more retries
		if retry_count > #retry_intervals then
			if not ok then
				callback({ error = true, message = 'Unable to decode response' })
			else
				callback({ error = decoded.error or true, message = decoded.message, code = decoded.code })
			end
			return
		end

		-- retry!
		after(retry_intervals[retry_count], function()
			make_http_request(url, method, callback, headers, post_data, options, retry_intervals, retry_count + 1, cancellation_token)
		end)
	end)
end

--- Make a HTTP request.
-- @param config The client config (see nakama.create_client).
-- @param url_path The request path.
-- @param query_params Table of query params (array values repeat the key).
-- @param method The HTTP method string.
-- @param post_data String of post data.
-- @param retry_policy Retry intervals in seconds, or nil for the client's.
-- @param cancellation_token Optional token from nakama.cancellation_token().
-- @param callback Called with the decoded response or an error table.
function M.http(config, url_path, query_params, method, post_data, retry_policy, cancellation_token, callback)
	local query_string = ''
	if next(query_params) then
		for query_key, query_value in pairs(query_params) do
			if type(query_value) == 'table' then
				for _, v in ipairs(query_value) do
					query_string = ('%s%s%s=%s'):format(query_string, (#query_string == 0 and '?' or '&'), query_key, uri_encode_component(tostring(v)))
				end
			else
				query_string = ('%s%s%s=%s'):format(query_string, (#query_string == 0 and '?' or '&'), query_key, uri_encode_component(tostring(query_value)))
			end
		end
	end
	local url = ('%s%s%s'):format(config.http_uri, url_path, query_string)

	local headers = {}
	headers['Accept'] = 'application/json'
	headers['Content-Type'] = 'application/json'
	if config.bearer_token then
		headers['Authorization'] = ('Bearer %s'):format(config.bearer_token)
	elseif config.username then
		local credentials = b64_encode(config.username .. ':' .. config.password)
		headers['Authorization'] = ('Basic %s'):format(credentials)
	end

	local options = {
		timeout = config.timeout,
	}

	log('HTTP', method, url)
	log('DATA', post_data)
	make_http_request(url, method, callback, headers, post_data, options, retry_policy or config.retry_policy, 1, cancellation_token)
end

----------------------------------------------------------------------
-- Socket
----------------------------------------------------------------------

--- Create a new socket with message handler.
-- @param config The client config.
-- @param on_message Function(socket, message) for decoded server messages.
-- @return A socket table.
function M.socket_create(config, on_message)
	assert(config, 'You must provide a config')
	assert(on_message, 'You must provide a message handler')

	local socket = {}
	socket.config = config
	socket.scheme = config.use_ssl and 'wss' or 'ws'
	socket.on_message = on_message

	return socket
end

--- Connect a created socket using web sockets.
-- @param socket The socket table, see socket_create.
-- @param callback Called with true once connected, or (false, message).
function M.socket_connect(socket, callback)
	assert(socket)
	assert(callback)

	local url = ('%s://%s:%d/ws?token=%s'):format(socket.scheme, socket.config.host, socket.config.port, uri_encode_component(socket.config.bearer_token))
	log(url)

	local worker = start_thread('nakama_ws_thread.lua')
	worker.tx:push({ type = 'connect', url = url, timeout = socket.config.timeout })
	socket.connection = worker
	socket.connect_callback = callback
	socket_workers[#socket_workers + 1] = { socket = socket, worker = worker }
end

--- Disconnect a created socket.
-- @param socket The socket table, see socket_create.
function M.socket_disconnect(socket)
	assert(socket)
	if socket.connection then
		socket.connection.tx:push({ type = 'close' })
		socket.connection = nil
	end
end

--- Send a socket message.
-- @param socket The socket table, see socket_create.
-- @param message The message table.
function M.socket_send(socket, message)
	assert(socket and socket.connection, 'Socket is not connected')
	assert(message)

	local data = json.encode(message)
	-- Fix encoding of match_create and status_update messages to send {} instead of []
	if message.match_create ~= nil or message.status_update ~= nil then
		data = string.gsub(data, '%[%]', '{}')
	end

	socket.connection.tx:push({ type = 'send', data = data })
end

----------------------------------------------------------------------
-- Pump
----------------------------------------------------------------------

local function fail_pending_http(reason)
	log('HTTP thread failed: ' .. tostring(reason))
	local callbacks = pending_http
	pending_http = {}
	http_worker = nil
	for _, on_response in pairs(callbacks) do
		on_response(0, '')
	end
end

local function update_http()
	if not http_worker then
		return
	end
	while true do
		local reply = http_worker.rx:pop()
		if not reply then
			break
		end
		if reply.fatal then
			fail_pending_http(reply.fatal)
			return
		end
		local on_response = pending_http[reply.id]
		pending_http[reply.id] = nil
		if on_response then
			if reply.error then
				log('HTTP error: ' .. reply.error)
				on_response(0, '')
			else
				on_response(reply.status, reply.body)
			end
		end
	end
	local err = http_worker.thread:getError()
	if err then
		fail_pending_http(err)
	end
end

local function update_timers()
	if #timers == 0 then
		return
	end
	local now = love.timer.getTime()
	local due = {}
	for i = #timers, 1, -1 do
		if timers[i].at <= now then
			due[#due + 1] = table.remove(timers, i)
		end
	end
	for i = #due, 1, -1 do
		due[i].fn()
	end
end

-- Delivers one socket's thread events. Returns false once the thread is
-- finished with.
local function update_socket(socket, worker)
	while true do
		local event = worker.rx:pop()
		if not event then
			break
		end
		-- After socket_disconnect the socket no longer hears from this
		-- worker (same as Defold's connection = nil).
		local attached = socket.connection == worker
		if event.type == 'connected' then
			if attached then
				socket.connect_callback(true)
			end
		elseif event.type == 'message' then
			if attached then
				local ok, message = pcall(json.decode, event.data)
				if ok then
					socket.on_message(socket, message)
				else
					log('Unable to decode socket message: ' .. tostring(event.data))
				end
			end
		elseif event.type == 'error' then
			if attached then
				socket.connection = nil
				socket.connect_callback(false, event.message)
			end
			return false
		elseif event.type == 'disconnected' then
			if attached then
				socket.connection = nil
				if socket.on_disconnect then
					socket.on_disconnect()
				end
			end
			return false
		end
	end
	local err = worker.thread:getError()
	if err then
		if socket.connection == worker then
			socket.connection = nil
			if socket.on_disconnect then
				socket.on_disconnect()
			end
		end
		return false
	end
	return true
end

local function update_sockets()
	for i = #socket_workers, 1, -1 do
		local entry = socket_workers[i]
		if not update_socket(entry.socket, entry.worker) then
			table.remove(socket_workers, i)
		end
	end
end

--- Deliver responses, socket events and due retries. Call every frame.
function M.update()
	update_http()
	update_timers()
	update_sockets()
end

--- Stop every I/O thread and drop pending callbacks (tests, mod unload).
function M.shutdown()
	for _, entry in ipairs(socket_workers) do
		entry.worker.tx:push({ type = 'close' })
		if entry.socket.connection == entry.worker then
			entry.socket.connection = nil
		end
	end
	socket_workers = {}
	if http_worker then
		http_worker.tx:push('shutdown')
		http_worker = nil
	end
	pending_http = {}
	timers = {}
end

return M
