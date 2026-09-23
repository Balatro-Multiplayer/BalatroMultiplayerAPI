-- Nakama HTTP worker thread (see lib/nakama/engine/love.lua).
-- Receives { id, method, url, headers, body, timeout } requests on
-- tx_channel and answers each with { id, status, body } or { id, error }
-- on rx_channel. One attempt per request: the engine schedules retries on
-- the main thread. The string 'shutdown' stops the thread.

local tx_channel, rx_channel = ... -- passed from main thread

-- Same bootstrap as mqtt_thread.lua: package paths, then the pre-read
-- module sources (the mod may live in a zip mount this thread's require()
-- can't read - see lib/thread_preload.lua).
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

local net_ok, net = pcall(require, 'nakama_net')
if not net_ok then
	rx_channel:push({ fatal = 'failed to load nakama_net: ' .. tostring(net) })
	return
end

-- Headers arrive as "Name: value\n" lines (channel tables must be flat).
local function parse_headers(text)
	local headers = {}
	for name, value in (text or ''):gmatch('([^:\n]+): ([^\n]*)') do
		headers[name] = value
	end
	return headers
end

while true do
	local request = tx_channel:demand()
	if request == 'shutdown' then
		return
	end
	if type(request) == 'table' then
		local ok, status, body = pcall(
			net.request,
			request.method,
			request.url,
			parse_headers(request.headers),
			request.body,
			request.timeout
		)
		if ok and status then
			rx_channel:push({ id = request.id, status = status, body = body })
		else
			rx_channel:push({ id = request.id, error = tostring(ok and body or status) })
		end
	end
end
