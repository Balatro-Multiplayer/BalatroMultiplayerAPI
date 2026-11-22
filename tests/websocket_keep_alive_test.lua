-- A connection that dies without a close (Wi-Fi change, router drop, sleep) reads as
-- quiet forever. The client pings a quiet line and calls it dead once nothing has
-- arrived for DEAD_SECONDS. Run from the MPAPI repository root:
-- luajit tests/websocket_keep_alive_test.lua
package.path = 'networking/?.lua;' .. package.path
local ws = require('websocket')

local checks, failed = 0, 0
local function check(name, got, want)
	checks = checks + 1
	if got ~= want then
		failed = failed + 1
		print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want)))
	end
end

local function fake_stream()
	local s = { sent = {}, incoming = {} }
	function s:send(bytes)
		self.sent[#self.sent + 1] = bytes:byte(1) % 16
		return true
	end
	function s:receive()
		return table.remove(self.incoming, 1) or ''
	end
	function s:close() end
	return s
end

local function pings(s)
	local n = 0
	for _, op in ipairs(s.sent) do
		if op == ws.OP_PING then n = n + 1 end
	end
	return n
end

local s = fake_stream()
local conn = ws.wrap(s, '', 100)

check('quiet under PING_SECONDS sends nothing', conn:keep_alive(100 + ws.PING_SECONDS - 1), nil)
check('no ping yet', pings(s), 0)

check('a quiet line is still alive', conn:keep_alive(100 + ws.PING_SECONDS), nil)
check('a quiet line gets a ping', pings(s), 1)
conn:keep_alive(100 + ws.PING_SECONDS + 1)
check('one ping per PING_SECONDS', pings(s), 1)

-- The server's pong (any bytes) counts as heard.
s.incoming[1] = string.char(0x8A, 0x00)
conn:poll(0, 100 + ws.PING_SECONDS + 2)
check('a pong keeps the line alive', conn:keep_alive(100 + ws.PING_SECONDS + 2 + ws.DEAD_SECONDS - 1), nil)

local dead = conn:keep_alive(100 + ws.PING_SECONDS + 2 + ws.DEAD_SECONDS)
check('nothing heard for DEAD_SECONDS is dead', type(dead), 'string')
check('the reason says why', dead and dead:find('no reply', 1, true) ~= nil, true)

-- An empty read (select timed out) is not hearing from the server.
local s2 = fake_stream()
local conn2 = ws.wrap(s2, '', 0)
conn2:poll(0, ws.DEAD_SECONDS)
check('an empty read does not count as heard', type(conn2:keep_alive(ws.DEAD_SECONDS)), 'string')

check('the server gives up later than we do (pong_wait 25 s)', ws.DEAD_SECONDS < 25, true)

if failed > 0 then
	os.exit(1)
end
print(('ok   %d checks'):format(checks))
