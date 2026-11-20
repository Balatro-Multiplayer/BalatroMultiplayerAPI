-- Wiring test for the request layer's hooks in the lobby transport: the real
-- networking/nakama_lobby.lua and api/lobby/nakama.lua run against a fake socket
-- and a fake MPAPI._internal.net that only records its calls.
-- Run from the MPAPI repository root: luajit tests/nakama_lobby_net_hooks_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local json = dofile('lib/nakama/util/json.lua')

local now = 0
love = { timer = {
	getTime = function()
		return now
	end,
} }

local action_types = {}
local net_calls
local socket, joins
local join_error = nil -- when set, match_join answers with this error

local function new_socket()
	local s = { handlers = {} }
	function s.on_match_data(fn)
		s.handlers.match_data = fn
	end
	function s.on_matchmaker_matched(fn)
		s.handlers.matched = fn
	end
	function s.on_party(fn)
		s.handlers.party = fn
	end
	function s.on_party_presence_event(fn)
		s.handlers.presence = fn
	end
	function s.on_party_leader(fn)
		s.handlers.leader = fn
	end
	function s.on_notifications(fn)
		s.handlers.notifications = fn
	end
	function s.on_error(fn)
		s.handlers.error = fn
	end
	function s.on_disconnect(fn)
		s.handlers.disconnect = fn
	end
	function s.connect(cb)
		cb(true)
	end
	function s.disconnect() end
	function s.match_join(id, _, metadata, cb)
		joins[#joins + 1] = { id = id, metadata = metadata }
		cb(join_error and { error = { message = join_error }, message = join_error } or {})
	end
	function s.match_leave(_, cb)
		if cb then
			cb()
		end
	end
	function s.match_data_send() end
	return s
end

local connection = {
	player_id = 'me',
	display_name = 'Me',
	nakama_client = {
		create_socket = function()
			socket = new_socket()
			return socket
		end,
		rpc_func = function(_, _, _, cb)
			cb({ payload = '{}' })
		end,
	},
	with_session = function(_, cb)
		cb({ user_id = 'me' })
	end,
	get_state = function()
		return 'connected'
	end,
}

MPAPI = {
	_internal = {},
	-- Only the wire constants load for real; the rest of the mod stays out.
	load_mpapi_file = function(path)
		if path == 'api/net/protocol.lua' then
			return dofile(path)
		end
	end,
	ActionType = setmetatable({ obj_buffer = {} }, {
		__call = function(_, spec)
			action_types[spec.key] = spec
		end,
	}),
	ActionTypes = {},
	get_current_lobby = function() end,
	LobbyEvent = setmetatable({}, {
		__index = function(_, k)
			return k
		end,
	}),
	ConnectionState = { CONNECTED = 'connected' },
	networking = {},
	set_player_ready = function() end,
	get_connection = function()
		return connection
	end,
	get_nakama_session = function()
		return { user_id = 'me' }
	end,
	json_encode = json.encode,
	json_decode = json.decode,
	chat = { init = function() end },
	match_log = function() end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')

-- The recording stand-in for the request layer (request_shell.lua's singleton).
local function fake_net()
	net_calls = {}
	local function record(name)
		return function(data)
			net_calls[#net_calls + 1] = { name = name, data = data }
		end
	end
	MPAPI._internal.net = {
		on_snapshot = record('on_snapshot'),
		on_answer = record('on_answer'),
		on_state_push = record('on_state_push'),
		on_dropped = record('on_dropped'),
		on_rejoined = record('on_rejoined'),
		on_closed = record('on_closed'),
	}
end

local function count(name)
	local n = 0
	for _, c in ipairs(net_calls) do
		if c.name == name then
			n = n + 1
		end
	end
	return n
end

-- A fresh transport (its module state is local) over a fresh socket and fake net.
local function setup()
	now = 0
	socket, joins, join_error = nil, {}, nil
	MPAPI.networking = {}
	dofile('networking/nakama_lobby.lua')
	fake_net()
	return MPAPI.networking.nakama_lobby
end

local function push(match_id, op, tbl)
	socket.handlers.match_data({ match_data = { match_id = match_id, op_code = op, data = json.encode(tbl) } })
end

-- Routing through api/lobby/nakama.lua and the drop / rejoin hooks.
do
	local NL = setup()
	check(NL.ServerOp.ANSWER == 114 and NL.ServerOp.STATE == 115, 'op numbers')
	local lobby = L.nakama_rejoin_lobby({ modId = 'm', matchId = 'M1', code = 'ABCD' })
	check(lobby == nil and #joins == 1, 'joined the match')
	check(joins[1].metadata.protocol == '1', 'join metadata carries the protocol as the string "1"')
	check(type(joins[1].metadata.protocol) == 'string', 'protocol is a string')

	local snap = { code = 'ABCD', hostId = 'a', players = {}, game = {}, protocol = 1, connectionId = 'c1', rev = 3, match = {} }
	push('M1', 100, snap)
	check(count('on_snapshot') == 1, 'op 100 reaches on_snapshot')
	check(net_calls[1].data.connectionId == 'c1' and net_calls[1].data.rev == 3, 'on_snapshot gets the decoded body')
	push('M1', 114, { reqId = 'c1:1', ok = true, rev = 4 })
	check(count('on_answer') == 1 and net_calls[#net_calls].data.reqId == 'c1:1', 'op 114 reaches on_answer')
	push('M1', 115, { rev = 4, changed = { k = 1 } })
	check(count('on_state_push') == 1 and net_calls[#net_calls].data.rev == 4, 'op 115 reaches on_state_push')
	push('OTHER', 114, { reqId = 'x', ok = true })
	check(count('on_answer') == 1, 'data of another match is not routed')

	NL._drop_socket()
	check(count('on_dropped') == 1, 'a socket disconnect calls on_dropped once')
	check(count('on_rejoined') == 0, 'not rejoined yet')
	now = now + 1
	NL.update()
	check(#joins == 2 and joins[2].id == 'M1', 'the rejoin joined the same match')
	check(count('on_rejoined') == 1, 'a successful rejoin calls on_rejoined once')
	check(count('on_closed') == 0, 'nothing closed the match')
end

-- Every way the match ends calls on_closed exactly once.
local function join_plain(NL)
	local err
	NL.join('M1', 'm', { data = function() end }, function(e)
		err = e
	end)
	return err
end

do
	local NL = setup()
	check(join_plain(NL) == nil and NL.in_match(), 'joined')
	NL.leave(function() end)
	check(count('on_closed') == 1 and not NL.in_match(), 'leave closes once')
end

do
	local NL = setup()
	join_plain(NL)
	check(NL.step_out() == 'M1', 'step_out left the match')
	check(count('on_closed') == 1, 'step_out closes once')
end

do
	local NL = setup()
	join_plain(NL)
	NL.forget()
	check(count('on_closed') == 1, 'forget closes once')
	NL.forget()
	check(count('on_closed') == 1, 'a second forget with no match closes nothing')
end

do
	local NL = setup()
	join_plain(NL)
	NL.reset()
	check(count('on_closed') == 1, 'reset closes once')
	NL.reset()
	check(count('on_closed') == 1, 'a second reset with no match closes nothing')
end

do
	local NL = setup()
	join_error = 'lobby full'
	check(join_plain(NL) == 'lobby full', 'the join error reaches the caller')
	check(count('on_closed') == 1 and not NL.in_match(), 'a join error closes once')
end

do
	local NL = setup()
	local lost
	NL.join('M1', 'm', {
		data = function() end,
		lost = function(reason, gave_up)
			lost = { reason = reason, gave_up = gave_up }
		end,
	}, function() end)
	NL._drop_socket()
	check(count('on_dropped') == 1 and count('on_closed') == 0, 'dropped, not closed')
	join_error = 'seat gone'
	now = now + 1000
	NL.update()
	check(lost ~= nil and lost.gave_up == true, 'the client gave up reconnecting')
	check(count('on_closed') == 1 and not NL.in_match(), 'lose closes once')
end

-- A player catching up when the socket drops says so again on the new session,
-- but only once the server has seated it (the rejoin snapshot). Sent on the join
-- answer it can reach the match before the join and be dropped.
do
	local NL = setup()
	local lobby
	L.nakama_rejoin_lobby({ modId = 'm', matchId = 'M1', code = 'ABCD' }, function(l)
		lobby = l
	end)
	local snap = { code = 'ABCD', hostId = 'a', players = {}, game = {}, protocol = 1, connectionId = 'c1', rev = 3, match = {} }
	push('M1', 100, snap)
	check(lobby ~= nil, 'the lobby is ready')
	lobby:set_catching_up(true)
	local sent = {}
	local function catching_up_sends()
		local n = 0
		for _, s in ipairs(sent) do
			if s.op == NL.ClientOp.CATCHING_UP then
				n = n + 1
			end
		end
		return n
	end
	NL._drop_socket()
	-- The rejoin connects a new socket: record what it sends, the join answer included.
	local create_socket = connection.nakama_client.create_socket
	connection.nakama_client.create_socket = function()
		local s = create_socket()
		s.match_data_send = function(_, op, data)
			sent[#sent + 1] = { op = op, data = data }
		end
		return s
	end
	now = now + 1
	NL.update()
	connection.nakama_client.create_socket = create_socket
	check(count('on_rejoined') == 1, 'rejoined')
	check(catching_up_sends() == 0, 'nothing about catching up goes out before the rejoin snapshot')
	push('M1', 100, snap)
	check(catching_up_sends() == 1, 'the rejoin snapshot sends catching up once')
	check(json.decode(sent[#sent].data).catchingUp == true, 'it says catching up')
	push('M1', 100, snap)
	check(catching_up_sends() == 2, 'a later snapshot (another rejoin) sends it again')
end

print(('nakama_lobby_net_hooks_test: ok (%d checks)'):format(checks))
