-- Contract test for api/net/request_core.lua: the resend schedule, revision rules,
-- request ids, request body and state merge. Pure, so no stubs.
-- Run from the MPAPI repository root: luajit tests/request_core_test.lua
local Core = dofile('api/net/request_core.lua')
local json = dofile('lib/nakama/util/json.lua')

local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local function names(entries)
	local out = {}
	for _, e in ipairs(entries) do
		out[#out + 1] = e.name
	end
	return table.concat(out, ',')
end

-- due: { name, entries, now, resend, timed_out }
local due_cases = {
	{ 'nothing pending', {}, 5, '', '' },
	{ 'fresh send, before first resend', { { name = 'a', born = 0, sent = true, resends = 0 } }, 0.25, '', '' },
	{ 'first resend point', { { name = 'a', born = 0, sent = true, resends = 0 } }, 0.5, 'a', '' },
	{ 'first resend already made', { { name = 'a', born = 0, sent = true, resends = 1 } }, 0.5, '', '' },
	{ 'second resend point', { { name = 'a', born = 0, sent = true, resends = 1 } }, 1.5, 'a', '' },
	{ 'last resend point', { { name = 'a', born = 0, sent = true, resends = 4 } }, 11.5, 'a', '' },
	{ 'all five resends made, waiting for the deadline', { { name = 'a', born = 0, sent = true, resends = 5 } }, 14.75, '', '' },
	{ 'deadline', { { name = 'a', born = 0, sent = true, resends = 5 } }, 15, '', 'a' },
	{ 'deadline beats a resend that is also due', { { name = 'a', born = 0, sent = true, resends = 2 } }, 20, '', 'a' },
	{ 'age counts from born, not from time zero', { { name = 'a', born = 10, sent = true, resends = 0 } }, 10.5, 'a', '' },
	{ 'unsent entry is never resent but can time out', { { name = 'a', born = 0, sent = false, resends = 0 }, { name = 'b', born = 0, sent = false, resends = 0 } }, 2, '', '' },
	{ 'unsent entry times out', { { name = 'a', born = 0, sent = false, resends = 0 } }, 15, '', 'a' },
	{
		'issue order is kept in both lists',
		{
			{ name = 'a', born = 0, sent = true, resends = 0 },
			{ name = 'b', born = 0, sent = true, resends = 0 },
			{ name = 'c', born = 14, sent = true, resends = 0 },
			{ name = 'd', born = 0, sent = true, resends = 5 },
			{ name = 'e', born = 15, sent = true, resends = 0 },
		},
		15.5,
		'c,e',
		'a,b,d',
	},
}
for _, c in ipairs(due_cases) do
	local out = Core.due(c[2], c[3])
	check(names(out.resend) == c[4], 'due resend: ' .. c[1] .. ': got ' .. names(out.resend))
	check(names(out.timed_out) == c[5], 'due timed_out: ' .. c[1] .. ': got ' .. names(out.timed_out))
end

check(table.concat(Core.RESEND_AT, ',') == '0.5,1.5,3.5,7.5,11.5', 'resend schedule')
check(Core.DEADLINE == 15, 'deadline')

-- resends_after_send: schedule points an entry of that age has passed
for _, c in ipairs({ { 0, 0 }, { 0.49, 0 }, { 0.5, 1 }, { 3.5, 3 }, { 11.5, 5 }, { 40, 5 } }) do
	check(Core.resends_after_send(c[1]) == c[2], 'resends_after_send ' .. c[1])
end

-- on_push: { local_rev, push_rev, opts, verdict }
local push_cases = {
	{ 5, 5, nil, 'drop' },
	{ 5, 4, nil, 'drop' },
	{ 5, 6, nil, 'apply' },
	{ 5, 7, nil, 'snapshot' },
	{ 5, 99, nil, 'snapshot' },
	{ 5, 7, { waiting = true }, 'ignore' },
	{ 5, 6, { waiting = true }, 'ignore' },
	{ 5, 5, { waiting = true }, 'drop' },
	{ 5, 3, { waiting = true }, 'drop' },
	{ 5, 5, { full = true }, 'apply_full' },
	{ 5, 9, { full = true }, 'apply_full' },
	{ 5, 9, { full = true, waiting = true }, 'apply_full' },
	{ 5, 4, { full = true }, 'drop' },
	{ 5, 4, { full = true, waiting = true }, 'drop' },
	{ nil, 3, nil, 'drop' },
	{ nil, 3, { full = true }, 'apply_full' },
}
for _, c in ipairs(push_cases) do
	local label = tostring(c[1]) .. ' <- ' .. c[2] .. (c[3] and (c[3].full and ' full' or '') .. (c[3].waiting and ' waiting' or '') or '')
	check(Core.on_push(c[1], c[2], c[3]) == c[4], 'on_push ' .. label .. ': got ' .. Core.on_push(c[1], c[2], c[3]))
end

-- next_id
local id, counter = Core.next_id('c4', 0)
check(id == 'c4:1' and counter == 1, 'first id of a connection')
id, counter = Core.next_id('c4', counter)
check(id == 'c4:2' and counter == 2, 'second id')
id, counter = Core.next_id('c12', 41)
check(id == 'c12:42' and counter == 42, 'ids carry the connection id')
-- ordering: ids from one counter are strictly increasing in issue order
local seen, c = {}, 0
for i = 1, 20 do
	local made
	made, c = Core.next_id('c1', c)
	check(made == 'c1:' .. i and not seen[made], 'ids distinct and in order')
	seen[made] = true
end

-- request_json: an empty payload stays an object, the rest round-trips
local body = Core.request_json(json.encode, 1, 'c4:8', 'snapshot', {})
check(body == '{"v":1,"reqId":"c4:8","type":"snapshot","payload":{}}', 'empty payload is {}: ' .. body)
local decoded = json.decode(Core.request_json(json.encode, 1, 'c4:7', 'pvp.ready', { runId = 'r-abc', roundId = 3, startingHands = 4 }))
check(decoded.v == 1 and decoded.reqId == 'c4:7' and decoded.type == 'pvp.ready', 'request header')
check(decoded.payload.runId == 'r-abc' and decoded.payload.roundId == 3 and decoded.payload.startingHands == 4, 'request payload')
check(json.decode(Core.request_json(json.encode, 1, 'x:1', 't', nil)).payload ~= nil, 'nil payload is {}')

-- apply_changes
local s1, keys = Core.apply_changes({}, { a = 1, b = { 2 } }, false)
check(s1.a == 1 and s1.b[1] == 2 and table.concat(keys, ',') == 'a,b', 'merge into empty')
local s2, keys2 = Core.apply_changes(s1, { a = 1, b = { 2 }, c = 'x' }, false)
check(table.concat(keys2, ',') == 'c' and s2.a == 1, 'an equal value is not a change')
local s3, keys3 = Core.apply_changes(s2, { a = 5 }, false)
check(s3.a == 5 and s3.c == 'x' and table.concat(keys3, ',') == 'a', 'partial merge keeps other keys')
local s4, keys4 = Core.apply_changes(s3, { a = 5, z = true }, true)
check(s4.c == nil and s4.b == nil and s4.z == true, 'full replaces the state')
check(table.concat(keys4, ',') == 'b,c,z', 'full reports removed keys and new keys: ' .. table.concat(keys4, ','))
check(s3.a == 5 and s3.b ~= nil, 'the old state is not modified')
local _, same = Core.apply_changes({ k = { x = { 1, 2 } } }, { k = { x = { 1, 2 } } }, true)
check(#same == 0, 'deep equal values are no change')

-- parse_snapshot
local legacy = Core.parse_snapshot({ lobbyCode = 'ABCD' })
check(legacy.supported == false, 'no protocol is unsupported')
check(Core.parse_snapshot({ protocol = 1, rev = 1 }).supported == false, 'no connectionId is unsupported')
check(Core.parse_snapshot({ protocol = '1', rev = 1, connectionId = 'c1' }).supported, 'protocol read with tonumber')
check(Core.parse_snapshot({ protocol = 'x', rev = 1, connectionId = 'c1' }).supported == false, 'non-numeric protocol is unsupported')
local v1 = Core.parse_snapshot({ protocol = 1, rev = 13, connectionId = 'c5', match = { k = 1 } })
check(v1.supported and v1.rev == 13 and v1.connection_id == 'c5' and v1.match.k == 1, 'v1 snapshot fields')
check(Core.parse_snapshot({ protocol = 1, connectionId = 'c1' }).rev == 0, 'missing rev is 0')
check(next(Core.parse_snapshot({ protocol = 1, connectionId = 'c1' }).match) == nil, 'missing match is empty')

-- encode_payload / request_body: the payload is encoded once and spliced in as is
check(Core.encode_payload(json.encode, nil) == '{}' and Core.encode_payload(json.encode, {}) == '{}', 'empty payload is {}')
check(Core.encode_payload(json.encode, { a = 1 }) == '{"a":1}', 'payload encoded')
check(not pcall(Core.encode_payload, json.encode, { x = 0 / 0 }), 'an unencodable payload throws')
check(Core.request_body(json.encode, 1, 'c4:8', 'snapshot', '{}') == Core.request_json(json.encode, 1, 'c4:8', 'snapshot', {}), 'request_body equals request_json')

print('request_core_test: ok (' .. checks .. ' checks)')
