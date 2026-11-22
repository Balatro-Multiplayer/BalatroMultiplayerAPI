-- Contract test: a socket worker that ends (a thread error, a disconnect, a
-- failed connect) always reaches the caller. Before 'connected' the connect
-- callback hears it; after, on_disconnect gets the reason and every request
-- still waiting for a reply gets a socket_closed error. Run from the MPAPI
-- repository root: luajit tests/socket_worker_loss_test.lua
local T = dofile('tests/support.lua')
local check = T.check

package.path = 'lib/?.lua;' .. package.path

local function channel()
	local queue = {}
	return {
		push = function(_, v)
			queue[#queue + 1] = v
		end,
		pop = function()
			return table.remove(queue, 1)
		end,
	}
end

local last_thread
love = {
	thread = {
		newThread = function()
			last_thread = {
				start = function() end,
				getError = function(self)
					return self.error
				end,
			}
			return last_thread
		end,
		newChannel = channel,
	},
	filesystem = { newFileData = function() end },
	timer = {
		getTime = function()
			return 0
		end,
	},
}
NFS = { read = function() return '' end }
MPAPI = {
	path = '',
	load_mpapi_file = function()
		return {
			read_single_module = function()
				return {}
			end,
		}
	end,
}

local engine = dofile('lib/nakama/engine/love.lua')

local function new_socket()
	local s = engine.socket_create({ host = 'h', port = 1, bearer_token = 't' }, function() end)
	s.requests = {}
	engine.socket_connect(s, function(ok, message)
		s.connect_result = { ok = ok, message = message }
	end)
	return s, s.connection, last_thread
end

-- A thread that dies before it connects is a failed connect.
local s, worker, thread = new_socket()
thread.error = 'boom'
engine.update()
check(s.connect_result and s.connect_result.ok == false, 'a thread error before connect fails the connect')
check(tostring(s.connect_result.message):find('boom'), 'the failed connect carries the thread error')
check(s.connection == nil, 'the dead worker is let go')

-- A thread that dies after it connects is a lost socket.
s, worker, thread = new_socket()
local lost_reason
s.on_disconnect = function(reason)
	lost_reason = reason
end
local reply
s.requests['1'] = function(result)
	reply = result
end
worker.rx:push({ type = 'connected' })
engine.update()
check(s.connect_result.ok == true, 'the connect succeeds')
thread.error = 'bad frame'
engine.update()
check(lost_reason and lost_reason:find('bad frame'), 'on_disconnect gets the thread error')
check(reply and reply.socket_closed == true and reply.error, 'a waiting request gets a socket_closed error')
check(next(s.requests) == nil, 'no request is left waiting')

-- A plain disconnect passes its reason on too.
s, worker, thread = new_socket()
lost_reason = nil
s.on_disconnect = function(reason)
	lost_reason = reason
end
worker.rx:push({ type = 'connected' })
worker.rx:push({ type = 'disconnected', message = '1006 gone' })
engine.update()
check(lost_reason == '1006 gone', 'on_disconnect gets the disconnect reason')

-- A worker the client already let go of reports nothing.
s, worker, thread = new_socket()
local told = false
s.on_disconnect = function()
	told = true
end
worker.rx:push({ type = 'connected' })
engine.update()
engine.socket_disconnect(s)
worker.rx:push({ type = 'disconnected', message = 'closed by client' })
engine.update()
check(not told, 'a socket closed on purpose does not report a loss')

T.done('socket_worker_loss_test')
