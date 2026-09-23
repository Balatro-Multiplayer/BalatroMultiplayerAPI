--[[
    Entry point for the vendored Nakama SDK (lib/nakama/, see its README).
    Only loaded for Nakama login (config use_nakama_auth, see
    api/connection/lifecycle.lua's create_nakama_client), which also pumps
    the engine's update() from MPAPI.update. core.lua doesn't load it.

      local sdk = MPAPI.load_mpapi_file('networking/nakama_sdk.lua').load()
      local client = sdk.nakama.create_client({
          host = '127.0.0.1', port = 7350, server_key = ...,
          engine = sdk.engine, -- lib/nakama/engine/love.lua
      })
      -- every frame: sdk.engine.update()

    load() registers every lib/nakama module (and the socket helpers the
    engine's tests use) into package.preload from pre-read source, the
    same way the MQTT thread gets luamqtt - require() can't read modules
    out of a zip-mounted mod (see lib/thread_preload.lua).
]]

local M = {}

local function register(sources)
	for name, source in pairs(sources) do
		if not package.preload[name] and not package.loaded[name] then
			package.preload[name] = function(...)
				local chunk = assert(load(source, '@' .. name))
				return chunk(...)
			end
		end
	end
end

-- Returns { nakama, engine, websocket, net }; later calls return the same
-- table.
function M.load()
	if M.nakama then
		return M
	end
	local thread_preload = MPAPI.load_mpapi_file('lib/thread_preload.lua')
	register(thread_preload.build_preload_table('lib/nakama', 'nakama'))
	register(thread_preload.read_single_module('networking/nakama_net.lua', 'nakama_net'))
	register(thread_preload.read_single_module('networking/websocket.lua', 'websocket'))

	M.nakama = require('nakama.nakama')
	M.engine = require('nakama.engine.love')
	M.websocket = require('websocket')
	M.net = require('nakama_net')
	return M
end

return M
