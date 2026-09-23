-- Nakama realtime socket thread, one per socket (see
-- lib/nakama/engine/love.lua).
--
-- tx_channel: after the bootstrap messages, { type = 'connect', url,
-- timeout }, then any number of { type = 'send', data } and finally
-- { type = 'close' }.
-- rx_channel: { type = 'connected' }, { type = 'message', data },
-- { type = 'error', message } (connect failed) and { type =
-- 'disconnected', message }. The thread exits after 'error' or
-- 'disconnected'.

local tx_channel, rx_channel = ... -- passed from main thread

-- Same bootstrap as mqtt_thread.lua (see lib/thread_preload.lua).
local setup = tx_channel:demand()
local pkg_path, pkg_cpath = setup:match('^setup\1(.*)\1(.*)$')
if pkg_path then
	package.path = pkg_path
end
if pkg_cpath then
	package.cpath = pkg_cpath
end

local preload = tx_channel:demand()
if type(preload) == 'table' then
	for mod_name, source in pairs(preload) do
		if not package.preload[mod_name] then
			package.preload[mod_name] = function(...)
				local chunk = assert(load(source, '@' .. mod_name))
				return chunk(...)
			end
		end
	end
end

local ws_ok, websocket = pcall(require, 'websocket')
if not ws_ok then
	rx_channel:push({ type = 'error', message = 'failed to load websocket: ' .. tostring(websocket) })
	return
end
local socket = require('socket')
math.randomseed(socket.gettime() * 10000) -- fallback mask source if OpenSSL is missing

-- How long each poll waits for server data before checking for sends.
local POLL_SECONDS = 0.01

local connect = tx_channel:demand()
if type(connect) ~= 'table' or connect.type ~= 'connect' then
	return
end

local conn, connect_err = websocket.connect(connect.url, connect.timeout)
if not conn then
	rx_channel:push({ type = 'error', message = tostring(connect_err) })
	return
end
rx_channel:push({ type = 'connected' })

while true do
	local command = tx_channel:pop()
	while command do
		if command.type == 'send' then
			local ok, send_err = conn:send_text(command.data)
			if not ok then
				conn:close()
				rx_channel:push({ type = 'disconnected', message = 'send failed: ' .. tostring(send_err) })
				return
			end
		elseif command.type == 'close' then
			conn:close()
			rx_channel:push({ type = 'disconnected', message = 'closed by client' })
			return
		end
		command = tx_channel:pop()
	end

	for _, event in ipairs(conn:poll(POLL_SECONDS)) do
		if event.type == 'message' then
			rx_channel:push({ type = 'message', data = event.data })
		elseif event.type == 'closed' then
			conn:close()
			local reason = event.code and (tostring(event.code) .. ' ' .. event.reason) or event.reason
			rx_channel:push({ type = 'disconnected', message = reason })
			return
		end
	end
end
