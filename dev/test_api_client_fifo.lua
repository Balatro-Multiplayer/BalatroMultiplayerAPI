-- Standalone regression test for networking/api_client: concurrent (overlapping)
-- HTTP requests must each receive their OWN response.
--
-- Bug: the client kept a single pending_callback + single on_http_response slot.
-- Two requests in flight at once (e.g. "Leave Queue & Continue" firing
-- leave_matchmaking_queue then join_lobby in one tick) clobbered each other: the
-- second overwrote the first's handler, so the first response ran the wrong
-- parser ("Failed to parse server response") and the second response was dropped.
--
-- Fix: a FIFO queue of handlers + a persistent router. The worker thread runs
-- requests sequentially and returns responses in order, so popping the front
-- matches each response to its request.
--
-- Run: luajit dev/test_api_client_fifo.lua

-- ── Stubs to load the real client + method files ────────────────────────────
local warns = {}
MPAPI = {
	networking = {},
	make_error = function(kind, message) return { kind = kind, message = message } end,
	ErrorKind = { SERVER = 'SERVER', TRANSPORT = 'TRANSPORT', AUTH_FAILED = 'AUTH_FAILED', NOT_CONNECTED = 'NOT_CONNECTED' },
	sendWarnMessage = function(msg) warns[#warns + 1] = msg end,
}

local LEAVE_BODY = 'LEAVE_RESPONSE'
local JOIN_BODY = 'JOIN_RESPONSE'
json = {
	encode = function(_) return '{}' end,
	decode = function(s)
		if s == LEAVE_BODY then return { left = true } end
		if s == JOIN_BODY then return { token = 'jwt-xyz', lobby = { code = 'ABC' } } end
		return nil
	end,
}

dofile('networking/api_client/client.lua')       -- defines MPAPI.networking.api_client
dofile('networking/api_client/matchmaking.lua')  -- adds leave_matchmaking_queue
dofile('networking/api_client/lobby.lua')        -- adds join_lobby
local AC = MPAPI.networking.api_client

local function make_fake_mqtt()
	local m = { tx_channel = true, sent = {} }
	local function rec(url) m.sent[#m.sent + 1] = url end
	m.http_post_auth = function(_self, url) rec(url) end
	m.http_delete_with_body_auth = function(_self, url) rec(url) end
	m.http_get_auth = function(_self, url) rec(url) end
	m.http_put_auth = function(_self, url) rec(url) end
	m.http_delete_auth = function(_self, url) rec(url) end
	return m
end

-- ── Harness ─────────────────────────────────────────────────────────────────
local failures = 0
local function check(cond, msg)
	if cond then print('PASS: ' .. msg) else failures = failures + 1; print('FAIL: ' .. msg) end
end

-- ── FIXED: two overlapping requests, responses delivered in order ───────────
print()
print('-- fixed: overlapping leave + join each get their own response --')
local client = AC.new(make_fake_mqtt(), 'http://x')
local leave_res, join_res
client:leave_matchmaking_queue('tok', {}, function(err, data) leave_res = { err = err, data = data } end)
client:join_lobby('tok', 'ABC', function(err, data) join_res = { err = err, data = data } end)

check(#client._queue == 2, 'both requests enqueued (neither clobbered the other)')

-- Worker returns responses in request order: leave first, then join.
client.mqtt.on_http_response(200, LEAVE_BODY)
client.mqtt.on_http_response(200, JOIN_BODY)

check(leave_res ~= nil and leave_res.err == nil and leave_res.data and leave_res.data.left == true,
	'leave callback received the LEAVE response')
check(join_res ~= nil and join_res.err == nil and join_res.data and join_res.data.token == 'jwt-xyz',
	'join callback received the JOIN response')
check(#client._queue == 0, 'queue drained after both responses')

-- ── FIXED: an error event routes to the right (front) request ───────────────
print()
print('-- fixed: an http error pops the front request only --')
local client2 = AC.new(make_fake_mqtt(), 'http://x')
local a_res, b_res
client2:leave_matchmaking_queue('tok', {}, function(err) a_res = err end)
client2:join_lobby('tok', 'ABC', function(err, data) b_res = { err = err, data = data } end)
client2.mqtt.on_http_error('boom')            -- first request fails
client2.mqtt.on_http_response(200, JOIN_BODY) -- second still succeeds
check(a_res ~= nil and a_res.kind == 'TRANSPORT', 'first request got the transport error')
check(b_res ~= nil and b_res.err == nil and b_res.data.token == 'jwt-xyz', 'second request still got its own success')

-- ── RED control: single-slot design (transcribed) drops/misroutes ───────────
-- Reproduces the pre-fix behaviour: one pending_callback + one self-clearing
-- on_http_response. The second request overwrites the first's handler.
print()
print('-- control: single-slot design misroutes overlapping requests --')
local old = { mqtt = make_fake_mqtt() }
local function old_setup_json(cb)
	old.pending = cb
	old.mqtt.on_http_response = function(status, body)
		old.mqtt.on_http_response = nil
		local c = old.pending; old.pending = nil
		if not c then return end
		local ok, data = pcall(json.decode, body)
		if not ok or not data then c({ kind = 'TRANSPORT' }, nil); return end
		c(nil, data)
	end
end
local function old_setup_http(cb) -- token-required (join)
	old.pending = cb
	old.mqtt.on_http_response = function(status, body)
		old.mqtt.on_http_response = nil
		local c = old.pending; old.pending = nil
		if not c then return end
		local ok, data = pcall(json.decode, body)
		if not ok or not data then c({ kind = 'TRANSPORT' }, nil); return end
		if not data.token then c({ kind = 'AUTH_FAILED' }, nil); return end
		c(nil, data)
	end
end
local old_leave, old_join
old_setup_json(function(err, data) old_leave = { err = err, data = data } end)   -- request 1
old_setup_http(function(err, data) old_join = { err = err, data = data } end)    -- request 2 overwrites handler
old.mqtt.on_http_response(200, LEAVE_BODY) -- leave's response arrives first...
if old.mqtt.on_http_response then old.mqtt.on_http_response(200, JOIN_BODY) end -- ...join's response dropped (handler nil)
check(old_leave == nil, 'control: leave callback NEVER fired (its handler was overwritten)')
check(old_join ~= nil and old_join.err and old_join.err.kind == 'AUTH_FAILED',
	'control: join callback got LEAVE body (no token) -> spurious error (reproduces the bug)')

-- ── Tripwire: a response with an empty queue warns (desync canary) ──────────
-- Should be impossible given the serial worker + no-in-place-swap invariants, so
-- if it ever happens the router warns instead of silently misrouting.
print()
print('-- tripwire: response with no pending request warns --')
local client3 = AC.new(make_fake_mqtt(), 'http://x')
warns = {}
client3:leave_matchmaking_queue('tok', {}, function() end)
client3.mqtt.on_http_response(200, LEAVE_BODY) -- normal: pops the one entry
check(#warns == 0, 'no warn while a request was pending')
client3.mqtt.on_http_response(200, LEAVE_BODY) -- extra response, queue now empty
check(#warns == 1, 'warned on the response that had nothing pending')
client3.mqtt.on_http_error('late') -- error with empty queue also warns
check(#warns == 2, 'warned on an error with nothing pending too')

-- ── Summary ─────────────────────────────────────────────────────────────────
print()
if failures == 0 then print('ALL TESTS PASSED'); os.exit(0) else print(failures .. ' TEST(S) FAILED'); os.exit(1) end
