-- Contract test for api/net/request_shell.lua with a fake socket and an injected
-- clock: a request is answered exactly once, survives a socket drop and is resent
-- in order under its original reqId after the rejoin snapshot, times out only on
-- connected time, and the shared state is revision-checked.
-- Run from the MPAPI repository root: luajit tests/request_shell_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local json = dofile('lib/nakama/util/json.lua')

love = { timer = {
	getTime = function()
		return 0
	end,
} }
MPAPI = {
	_internal = {},
	load_mpapi_file = function(file)
		return dofile(file)
	end,
	update = function() end,
	json_encode = json.encode,
	sendWarnMessage = function() end,
	networking = {},
}
local Core = dofile('api/net/request_core.lua')
local Protocol = dofile('api/net/protocol.lua')
local Shell = dofile('api/net/request_shell.lua')

local function fixture(name)
	local f = assert(io.open('tests/fixtures/net-v1/' .. name .. '.json', 'rb'), 'missing fixture ' .. name)
	local text = f:read('*a')
	f:close()
	return json.decode(text)
end

-- A fake socket: sends are recorded (and refused while the socket is down).
local function new_world()
	local w = { t = 0, in_match = true, live = true, sent = {}, log = {}, warned = {} }
	w.net = Shell.new({
		clock = function()
			return w.t
		end,
		encode = json.encode,
		warn = function(m)
			w.warned[#w.warned + 1] = m
		end,
		transport = {
			in_match = function()
				return w.in_match
			end,
			live = function()
				return w.live
			end,
			send = function(op, body)
				if not w.live then
					return false
				end
				local msg = json.decode(body)
				w.sent[#w.sent + 1] = { op = op, t = w.t, msg = msg, body = body }
				w.log[#w.log + 1] = 'send ' .. msg.reqId
				return true
			end,
		},
	})
	return w
end

-- Advances the clock in exact quarter seconds, one frame each.
local function tick(w, seconds)
	for _ = 1, math.floor(seconds / 0.25 + 0.5) do
		w.t = w.t + 0.25
		w.net.update()
	end
end

local function snapshot(w, conn, rev, match)
	w.net.on_snapshot({ lobbyCode = 'ABCD', protocol = 1, connectionId = conn, rev = rev, match = match or {} })
end

local function issue(w, type_, payload)
	local r = { calls = {} }
	r.cancel = w.net.request(type_, payload, function(ok, result)
		r.calls[#r.calls + 1] = { ok = ok, result = result }
	end)
	return r
end

local function answer_ok(w, req_id, rev)
	w.net.on_answer({ reqId = req_id, ok = true, rev = rev or 1 })
end

local function reasons(r)
	local out = {}
	for _, c in ipairs(r.calls) do
		out[#out + 1] = tostring(c.ok) .. ':' .. tostring(c.ok and c.result.rev or c.result.reason)
	end
	return table.concat(out, ',')
end

local ready_payload = { runId = 'r-abc', roundId = 3, startingHands = 4 }

-- Constants agree with the transport tables.
do
	local saved = MPAPI.networking
	MPAPI.networking = {}
	dofile('networking/nakama_lobby.lua')
	local NL = MPAPI.networking.nakama_lobby
	MPAPI.networking = saved
	check(NL.ClientOp.REQUEST == Protocol.Op.REQUEST and Protocol.Op.REQUEST == 8, 'REQUEST op')
	check(NL.ServerOp.ANSWER == Protocol.Op.ANSWER and Protocol.Op.ANSWER == 114, 'ANSWER op')
	check(NL.ServerOp.STATE == Protocol.Op.STATE and Protocol.Op.STATE == 115, 'STATE op')
	check(NL.ServerOp.SNAPSHOT == Protocol.Op.SNAPSHOT and Protocol.Op.SNAPSHOT == 100, 'SNAPSHOT op')
	check(Protocol.PROTOCOL_VERSION == 1, 'protocol version')
	check(type(NL.send_raw) == 'function' and type(NL.is_live) == 'function' and type(NL.in_match) == 'function', 'transport hooks exist')
end

-- Public surface is installed on MPAPI and delegates to the singleton.
check(type(MPAPI.request) == 'function' and type(MPAPI.on_state) == 'function' and type(MPAPI.get_state) == 'function', 'public surface')
check(MPAPI._internal.net ~= nil and type(MPAPI._internal.net.on_snapshot) == 'function', 'internal handle for the lobby hooks')

-- Basic: send under connectionId:counter, one result per answer.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local a = issue(w, 'pvp.ready', ready_payload)
	local b = issue(w, 'pvp.unready', { runId = 'r-abc', roundId = 3 })
	check(#w.sent == 2 and w.sent[1].msg.reqId == 'c4:1' and w.sent[2].msg.reqId == 'c4:2', 'ids count from 1 per connection')
	check(w.sent[1].op == 8 and w.sent[1].msg.v == 1 and w.sent[1].msg.type == 'pvp.ready', 'request body')
	check(w.sent[1].msg.payload.startingHands == 4, 'payload sent')
	answer_ok(w, 'c4:1', 12)
	check(reasons(a) == 'true:12', 'ok answer carries rev')
	check(#b.calls == 0, 'the other request is still pending')
	w.net.on_answer({ reqId = 'c4:2', ok = false, reason = 'round_over' })
	check(reasons(b) == 'false:round_over', 'refusal carries reason')
	check(b.calls[1].result.rev == nil, 'a refusal that changed nothing has no rev')
	local c = issue(w, 'pvp.shop', { runId = 'r-abc' })
	w.net.on_answer({ reqId = 'c4:3', ok = false, reason = 'bad_spend', rev = 13 })
	check(c.calls[1].result.reason == 'bad_spend' and c.calls[1].result.rev == 13, 'a recorded refusal carries the rev it is in')
	local d = issue(w, 'pvp.shop', { runId = 'r-abc' })
	w.net.on_answer({ reqId = 'c4:4', ok = false, reason = 'bad_spend', key = 'shop:2' })
	check(d.calls[1].result.key == 'shop:2', 'a refusal keeps the key the server named')
end

-- (a) drop mid-request, rejoin with a new connectionId: snapshot first, then the
-- resend under the old reqId, answer delivered once.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	w.live = false
	w.net.on_dropped()
	tick(w, 2)
	check(#w.sent == 1 and #r.calls == 0, 'nothing sent and nothing ended while the socket is down')
	w.net.on_state('pvp.ready', function()
		w.log[#w.log + 1] = 'state'
	end)
	w.live = true
	snapshot(w, 'c5', 12, { ['pvp.ready'] = { round = 3 } })
	check(w.log[#w.log - 1] == 'state' and w.log[#w.log] == 'send c4:1', 'snapshot applied first, then the resend: ' .. table.concat(w.log, ' | '))
	check(#w.sent == 2 and w.sent[2].msg.reqId == 'c4:1' and w.sent[2].msg.type == 'pvp.ready', 'resend keeps the original reqId')
	check(w.sent[2].msg.payload.roundId == 3, 'resend keeps the payload')
	answer_ok(w, 'c4:1', 13)
	answer_ok(w, 'c4:1', 13)
	check(#r.calls == 1 and r.calls[1].ok, 'answer delivered once')
	check(w.net.pending_count() == 0, 'nothing left pending')
end

-- (a') the snapshot comes before the socket counts as up: the resend waits for it.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	w.live = false
	w.net.on_dropped()
	snapshot(w, 'c5', 12)
	check(#w.sent == 1, 'no send while the seat is not back')
	w.live = true
	w.net.on_rejoined()
	check(#w.sent == 2 and w.sent[2].msg.reqId == 'c4:1', 'resent when the rejoin completes')
	w.net.on_rejoined()
	check(#w.sent == 2, 'a second rejoined notice sends nothing again')
	answer_ok(w, 'c4:1')
	check(#r.calls == 1, 'once')
end

-- (b) Ready then Unready pending across a drop are resent in that order, and a
-- request made during the rejoin queues behind them under the new connection.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local ready = issue(w, 'pvp.ready', ready_payload)
	local unready = issue(w, 'pvp.unready', { runId = 'r-abc', roundId = 3 })
	w.live = false
	w.net.on_dropped()
	local third = issue(w, 'pvp.ready', ready_payload)
	check(#w.sent == 2, 'a request during the drop is held')
	w.live = true
	snapshot(w, 'c5', 12)
	local order = {}
	for i = 3, #w.sent do
		order[#order + 1] = w.sent[i].msg.reqId .. '=' .. w.sent[i].msg.type
	end
	check(table.concat(order, ',') == 'c4:1=pvp.ready,c4:2=pvp.unready,c5:1=pvp.ready', 'resend order: ' .. table.concat(order, ','))
	answer_ok(w, 'c4:2')
	answer_ok(w, 'c4:1')
	answer_ok(w, 'c5:1')
	check(#ready.calls == 1 and #unready.calls == 1 and #third.calls == 1, 'each ends once')
end

-- (b') requests made before the first connectionId queue, then go out in order.
do
	local w = new_world()
	local one = issue(w, 'pvp.ready', ready_payload)
	local two = issue(w, 'pvp.unready', { runId = 'r-abc', roundId = 3 })
	tick(w, 1)
	check(#w.sent == 0, 'nothing sent before the first snapshot')
	snapshot(w, 'c1', 1)
	check(#w.sent == 2 and w.sent[1].msg.reqId == 'c1:1' and w.sent[2].msg.reqId == 'c1:2', 'queued requests take the first ids in order')
	answer_ok(w, 'c1:1')
	answer_ok(w, 'c1:2')
	check(#one.calls == 1 and #two.calls == 1, 'answered')
end

-- (c) a 40 s drop times nothing out, then the request is answered.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	tick(w, 1)
	w.live = false
	w.net.on_dropped()
	tick(w, 40)
	check(#r.calls == 0, 'no timeout during a 40 s drop')
	w.live = true
	snapshot(w, 'c5', 12)
	tick(w, 0.25)
	check(#r.calls == 0, 'still pending after the rejoin')
	answer_ok(w, 'c4:1', 13)
	check(reasons(r) == 'true:13', 'answered after the drop')
	tick(w, 30)
	check(#r.calls == 1, 'no late timeout')
end

-- (c') only connected time counts: 14 s up, a long drop, then 1 s more.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	tick(w, 14)
	w.live = false
	w.net.on_dropped()
	tick(w, 60)
	w.live = true
	snapshot(w, 'c5', 12)
	tick(w, 0.75)
	check(#r.calls == 0, 'connected time is 14.75 s: not yet')
	tick(w, 0.25)
	check(reasons(r) == 'false:timeout', 'timeout at 15 s of connected time')
end

-- (d) 15 s connected with no answer: resends on schedule, then timeout exactly once.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	tick(w, 14.75)
	check(#r.calls == 0, 'pending just before the deadline')
	local times = {}
	for _, s in ipairs(w.sent) do
		check(s.msg.reqId == 'c4:1', 'resends keep the reqId')
		times[#times + 1] = s.t
	end
	check(table.concat(times, ',') == '0,0.5,1.5,3.5,7.5,11.5', 'send schedule: ' .. table.concat(times, ','))
	tick(w, 0.25)
	check(reasons(r) == 'false:timeout', 'timeout reason')
	tick(w, 20)
	check(#r.calls == 1 and #w.sent == 6, 'timeout once, nothing sent after')
	check(w.net.pending_count() == 0, 'removed on timeout')
	answer_ok(w, 'c4:1')
	check(#r.calls == 1, 'a late answer is ignored')
end

-- (e) a gap sends one snapshot request; STATE is ignored until the full STATE of
-- snapshot_exchange.json (fixture order), which then applies.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	for _ = 1, 7 do
		local r = issue(w, 'pvp.ready', ready_payload)
		check(#r.calls == 0, 'pending')
	end
	for i = 1, 7 do
		answer_ok(w, 'c4:' .. i)
	end
	check(#w.sent == 7, 'seven requests sent')
	w.net.on_state_push(fixture('state_round_started')) -- rev 13 against local 11: a gap
	check(#w.sent == 8 and w.sent[8].msg.type == 'snapshot' and w.sent[8].msg.reqId == 'c4:8', 'one snapshot request, id c4:8')
	check(w.sent[8].body:find('"payload":{}', 1, true) ~= nil, 'snapshot payload is an object')
	w.net.on_state_push({ rev = 14, changed = { ['pvp.ready'] = { round = 9 } } })
	w.net.on_state_push({ rev = 16, changed = { ['pvp.ready'] = { round = 9 } } })
	w.net.on_state_push(fixture('state_round_started'))
	check(#w.sent == 8, 'no second snapshot request while waiting')
	local value, rev = w.net.get_state('pvp.ready')
	check(value == nil and rev == 11, 'STATE ignored until answered')
	local exchange = fixture('snapshot_exchange')
	check(exchange[1].op == 115 and exchange[2].op == 114, 'fixture order is STATE then ANSWER')
	w.net.on_state_push(exchange[1].body)
	value, rev = w.net.get_state('pvp.ready')
	check(rev == 13 and value.round == 3, 'the full STATE applies while waiting')
	w.net.on_answer(exchange[2].body)
	check(w.net.pending_count() == 0, 'the snapshot answer ends the request')
	w.net.on_state_push({ rev = 14, changed = { ['pvp.ready'] = { round = 4 } } })
	value, rev = w.net.get_state('pvp.ready')
	check(rev == 14 and value.round == 4, 'next revision applies again')
	w.net.on_state_push({ rev = 16, changed = { ['pvp.ready'] = { round = 6 } } })
	check(#w.sent == 9 and w.sent[9].msg.type == 'snapshot' and w.sent[9].msg.reqId == 'c4:9', 'a new gap asks again')
	w.net.on_state_push({ rev = 14, changed = { ['pvp.ready'] = { round = 99 } } })
	check(select(2, w.net.get_state('pvp.ready')) == 14, 'old rev dropped')
end

-- (e') a full STATE whose rev equals the local one still applies (and a smaller one does not).
do
	local w = new_world()
	snapshot(w, 'c4', 13)
	w.net.on_state_push({ rev = 13, full = true, changed = { k = 1 } })
	check(w.net.get_state('k') == 1, 'full with equal rev applies')
	w.net.on_state_push({ rev = 12, full = true, changed = { k = 2 } })
	check(w.net.get_state('k') == 1, 'full with an older rev is dropped')
end

-- (f) a snapshot with no protocol: every pending and future request ends not_supported.
do
	local w = new_world()
	local queued = issue(w, 'pvp.ready', ready_payload)
	w.net.on_snapshot(fixture('snapshot_legacy'))
	check(reasons(queued) == 'false:not_supported', 'pending ended at once')
	local later = issue(w, 'pvp.ready', ready_payload)
	check(#later.calls == 0, 'never from inside request()')
	tick(w, 0.25)
	check(reasons(later) == 'false:not_supported', 'future request ended on the next frame')
	check(#w.sent == 0 and w.net.pending_count() == 0, 'nothing sent')
end

-- (g) duplicate and unknown ANSWERs: on_result runs once.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	answer_ok(w, 'c4:1', 12)
	answer_ok(w, 'c4:1', 12)
	w.net.on_answer({ reqId = 'c4:1', ok = false, reason = 'round_over' })
	w.net.on_answer({ reqId = 'c4:99', ok = true, rev = 3 })
	w.net.on_answer({})
	w.net.on_answer(nil)
	check(reasons(r) == 'true:12', 'one result')
end

-- A refusal that the server does not store (rate_limited) stays pending and is resent on schedule.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	w.net.on_answer({ reqId = 'c4:1', ok = false, reason = 'rate_limited' })
	check(#r.calls == 0 and w.net.pending_count() == 1, 'rate_limited keeps the request pending')
	tick(w, 0.5)
	check(#w.sent == 2 and w.sent[2].msg.reqId == 'c4:1', 'and it is resent')
end

-- Cancel: one `cancelled` result, a late answer is ignored.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	r.cancel()
	r.cancel()
	check(reasons(r) == 'false:cancelled' and w.net.pending_count() == 0, 'cancelled once')
	answer_ok(w, 'c4:1')
	check(#r.calls == 1, 'late answer ignored')
	w.in_match = false
	local d = issue(w, 'x', {})
	d.cancel()
	tick(w, 0.25)
	check(reasons(d) == 'false:cancelled', 'cancel before the deferred result wins, still once')
end

-- No lobby: not_connected on the next frame.
do
	local w = new_world()
	w.in_match = false
	local r = issue(w, 'pvp.ready', ready_payload)
	check(#r.calls == 0, 'not from inside request()')
	tick(w, 0.25)
	check(reasons(r) == 'false:not_connected', 'no lobby')
end

-- Leaving the lobby: pending end not_connected, state cleared, subscribers told, a new lobby starts clean.
do
	local w = new_world()
	snapshot(w, 'c4', 11, { ['pvp.ready'] = { round = 2 } })
	local one = issue(w, 'pvp.ready', ready_payload)
	local two = issue(w, 'pvp.unready', {})
	local seen = {}
	w.net.on_state('pvp.ready', function(value, rev)
		seen[#seen + 1] = tostring(value and value.round) .. '@' .. tostring(rev)
	end)
	check(seen[1] == '2@11', 'subscriber gets the current value at once')
	w.in_match = false
	w.net.on_closed()
	check(reasons(one) == 'false:not_connected' and reasons(two) == 'false:not_connected', 'pending end not_connected')
	check(w.net.get_state('pvp.ready') == nil and select(2, w.net.get_state('pvp.ready')) == nil, 'state cleared')
	check(seen[2] == 'nil@nil', 'subscriber told the value is gone')
	check(w.net.pending_count() == 0, 'nothing pending')
	w.in_match = true
	w.live = true
	local again = issue(w, 'pvp.ready', ready_payload)
	snapshot(w, 'c9', 1)
	check(w.sent[#w.sent].msg.reqId == 'c9:1' and #again.calls == 0, 'a new lobby starts a new connection counter')
end

-- (h) on_state: value now, every change, unsubscribe stops it.
do
	local w = new_world()
	snapshot(w, 'c4', 11, { ['pvp.ready'] = { round = 2 }, other = 1 })
	local seen = {}
	local off = w.net.on_state('pvp.ready', function(value, rev)
		seen[#seen + 1] = value.round .. '@' .. rev
	end)
	check(#seen == 1 and seen[1] == '2@11', 'called now with the known value')
	local unknown = {}
	w.net.on_state('nothing', function()
		unknown[#unknown + 1] = true
	end)
	check(#unknown == 0, 'not called for an unknown key')
	w.net.on_state_push({ rev = 12, changed = { other = 2 } })
	check(#seen == 1, 'not called for another key')
	w.net.on_state_push({ rev = 13, changed = { ['pvp.ready'] = { round = 3 } } })
	check(#seen == 2 and seen[2] == '3@13', 'called on change')
	off()
	off()
	w.net.on_state_push({ rev = 14, changed = { ['pvp.ready'] = { round = 4 } } })
	check(#seen == 2, 'unsubscribed')
	local value, rev = w.net.get_state('pvp.ready')
	check(value.round == 4 and rev == 14, 'get_state still reads the value')
	-- a subscriber that unsubscribes another while being notified
	local log = {}
	local off_b
	w.net.on_state('k', function()
		log[#log + 1] = 'a'
		off_b()
	end)
	off_b = w.net.on_state('k', function()
		log[#log + 1] = 'b'
	end)
	w.net.on_state_push({ rev = 15, changed = { k = 1 } })
	check(table.concat(log) == 'a', 'a subscriber removed mid-notification is not called')
	-- a rejoin snapshot that changes nothing tells nobody
	local before = #seen
	snapshot(w, 'c5', 15, { ['pvp.ready'] = { round = 4 }, other = 2, k = 1 })
	check(#seen == before, 'unchanged value is not announced again')
end

-- A throwing callback does not break the layer.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	w.net.request('t', {}, function()
		error('boom')
	end)
	answer_ok(w, 'c4:1')
	check(#w.warned == 1 and w.net.pending_count() == 0, 'error in on_result is logged and contained')
end

-- (i) every fixture is decoded and consumed without error.
do
	local files = {
		'request_ready',
		'request_snapshot',
		'answer_ok',
		'answer_round_over',
		'answer_bad_round',
		'state_ready_push',
		'state_round_started',
		'state_full',
		'snapshot_v1',
		'snapshot_legacy',
		'snapshot_exchange',
	}
	local fx = {}
	for _, name in ipairs(files) do
		fx[name] = fixture(name)
		check(type(fx[name]) == 'table', 'fixture decodes: ' .. name)
	end

	-- the bodies this client produces equal the golden requests
	local ready = json.decode(Core.request_json(json.encode, 1, 'c4:7', 'pvp.ready', fx.request_ready.payload))
	check(Core.deep_equal(ready, fx.request_ready), 'request_ready.json')
	local snap = json.decode(Core.request_json(json.encode, 1, 'c4:8', 'snapshot', {}))
	check(Core.deep_equal(snap, fx.request_snapshot), 'request_snapshot.json')

	-- answers
	for _, case in ipairs({ { 'answer_ok', 7, 'true:12' }, { 'answer_round_over', 7, 'false:round_over' }, { 'answer_bad_round', 9, 'false:bad_round' } }) do
		local w = new_world()
		snapshot(w, 'c4', 11)
		local made = {}
		for i = 1, case[2] do
			made[i] = issue(w, 'pvp.ready', ready_payload)
		end
		w.net.on_answer(fx[case[1]])
		check(reasons(made[case[2]]) == case[3], case[1] .. ' ended its request: ' .. reasons(made[case[2]]))
		check(w.net.pending_count() == case[2] - 1, case[1] .. ' ended only its request')
	end

	-- state pushes and snapshots
	local w = new_world()
	w.net.on_snapshot(fx.snapshot_v1)
	local value, rev = w.net.get_state('pvp.ready')
	check(rev == 13 and value.round == 3 and value.lastStart.firstPlayer == 'u1', 'snapshot_v1.json')
	w.net.on_state_push(fx.state_ready_push)
	check(select(2, w.net.get_state('pvp.ready')) == 13, 'state_ready_push.json (rev 12) is old')
	w.net.on_state_push(fx.state_full)
	check(select(2, w.net.get_state('pvp.ready')) == 13, 'state_full.json at the same rev applies')
	local w2 = new_world()
	snapshot(w2, 'c4', 12)
	w2.net.on_state_push(fx.state_round_started)
	value, rev = w2.net.get_state('pvp.ready')
	check(rev == 13 and value.round == 3, 'state_round_started.json is the next rev')
	local w3 = new_world()
	w3.net.on_snapshot(fx.snapshot_legacy)
	check(#w3.warned == 0, 'snapshot_legacy.json consumed')
	check(Core.parse_snapshot(fx.snapshot_legacy).supported == false, 'snapshot_legacy.json is unsupported')
end

-- A frame stall while connected (one 20 s tick) does not time the request out
-- before the answer buffered during it is read.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local r = issue(w, 'pvp.ready', ready_payload)
	tick(w, 1)
	w.t = w.t + 20
	w.net.update()
	check(#r.calls == 0, 'a 20 s stall does not time out')
	answer_ok(w, 'c4:1', 12)
	check(reasons(r) == 'true:12', 'the answer read after the stall is ok, not timeout')
end

-- A request the layer cannot send is refused on the next frame with bad_payload.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local sparse = { [1] = 'a', [3] = 'c' }
	local mixed = { 'a', b = 1 }
	local nan = { x = 0 / 0 }
	local cases = {
		{ 'non-table payload', 'pvp.ready', 'oops' },
		{ 'number payload', 'pvp.ready', 5 },
		{ 'non-string type', 7, {} },
		{ 'nil type', nil, {} },
		{ 'sparse payload', 'pvp.ready', sparse },
		{ 'mixed keys', 'pvp.ready', mixed },
		{ 'NaN value', 'pvp.ready', nan },
	}
	for _, case in ipairs(cases) do
		local r
		local threw = not pcall(function()
			r = issue(w, case[2], case[3])
		end)
		check(not threw, case[1] .. ': request() does not throw')
		if r then
			check(#r.calls == 0, case[1] .. ': the result is not delivered from inside request()')
			tick(w, 0.25)
			check(reasons(r) == 'false:bad_payload', case[1] .. ': bad_payload, got ' .. reasons(r))
		end
	end
	check(#w.sent == 0 and w.net.pending_count() == 0, 'nothing bad was sent or left pending')
	check(#w.warned == 0, 'no warning from refused requests')
	tick(w, 20)
	-- The layer still works after refusals, and an empty payload stays an object.
	local ok = issue(w, 'snapshot', nil)
	check(#w.sent == 1 and w.sent[1].body:find('"payload":{}', 1, true) ~= nil, 'a nil payload goes out as {}')
	answer_ok(w, 'c4:1', 12)
	check(reasons(ok) == 'true:12', 'later request is answered')
end

-- Changing the payload after request() changes neither the first send nor a resend.
do
	local w = new_world()
	snapshot(w, 'c4', 11)
	local payload = { runId = 'r-abc', roundId = 3, startingHands = 4 }
	local r = issue(w, 'pvp.ready', payload)
	local first = w.sent[1].body
	payload.roundId = 99
	payload.extra = true
	w.live = false
	w.net.on_dropped()
	tick(w, 1)
	w.live = true
	snapshot(w, 'c5', 12)
	check(#w.sent == 2 and w.sent[2].msg.reqId == 'c4:1', 'resent under the old reqId')
	check(w.sent[2].body == first, 'the resend body is byte-equal to the first send')
	check(w.sent[2].msg.payload.roundId == 3 and w.sent[2].msg.payload.extra == nil, 'later edits are not sent')
	answer_ok(w, 'c4:1', 13)
	check(reasons(r) == 'true:13', 'answered once')
end

print('request_shell_test: ok (' .. checks .. ' checks)')
