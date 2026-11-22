-- Contract test: a lobby that outlives a connection teardown (MPAPI.reconnect) rejoins its match once
-- the connection is back, without the crash-relaunch prompt.
-- Run from the MPAPI repository root: luajit tests/reconnect_reattach_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local joined = {}
local in_match = false
local listener, join_cb
local NL = {
	ClientOp = {},
	ServerOp = { SNAPSHOT = 100 },
	in_match = function() return in_match end,
	join = function(match_id, mod_id, l, cb)
		joined[#joined + 1] = match_id
		listener, join_cb = l, cb
	end,
	current = function(cb) cb(nil, nil) end,
}

MPAPI = {
	ConnectionState = { DISCONNECTED = 'disconnected', CONNECTED = 'connected' },
	LobbyEvent = {},
	networking = { nakama_lobby = NL },
	_internal = {},
	get_nakama_session = function() return { user_id = 'me' } end,
	sendWarnMessage = function() end,
	match_log = function() end,
	ErrorKind = { SERVER = 'server' },
	make_error = function(kind, message) return { kind = kind, message = message } end,
	is_forfeited_refusal = function() return false end,
	standing = { parse_rejoin_refusal = function() return nil end },
}
dofile('api/lobby/nakama.lua')
local L = MPAPI._internal.lobby
local calls = {}
L.apply_snapshot = function(lobby, snapshot, announce) calls[#calls + 1] = 'snapshot:' .. tostring(announce) end
L.resend_log_events = function() calls[#calls + 1] = 'resend' end
L.cleanup = function() calls[#calls + 1] = 'cleanup' end
MPAPI._internal.is_seat_held_refusal = function() return false end
dofile('networking/connection.lua')
local connection = MPAPI.networking.connection

local function seated_lobby()
	return {
		_nakama = true,
		_match_id = 'match-1',
		_nakama_ready = true,
		_destroyed = false,
		code = 'ABC123',
		_fire = function() end,
		set_catching_up = function() calls[#calls + 1] = 'catching_up' end,
	}
end

local function check_seat(current)
	L.current = current
	L.nakama_check_current = function(cb) cb(nil) end
	connection._check_nakama_lobby_seat({ state = 'connected' })
end

-- the teardown forgot the match; the lobby object is still current
joined = {}
in_match = false
check_seat(seated_lobby())
check(#joined == 1 and joined[1] == 'match-1', 'the lobby rejoins its own match')

-- a match already held (a socket drop is rejoining it): no second join
joined = {}
in_match = true
check_seat(seated_lobby())
check(#joined == 0, 'no second join while the match is held')

-- a lobby that never got its first snapshot is not rejoined
joined = {}
in_match = false
local unready = seated_lobby()
unready._nakama_ready = nil
check_seat(unready)
check(#joined == 0, 'a lobby that never attached is left alone')

-- a destroyed lobby is not rejoined
joined = {}
local gone = seated_lobby()
gone._destroyed = true
check_seat(gone)
check(#joined == 0, 'a destroyed lobby is left alone')

-- the join's snapshot is a rejoin: the view is applied as one, unconfirmed events go out again, and
-- the server hears again that the client is catching up (its new session starts as live)
joined, calls, in_match = {}, {}, false
local catching = seated_lobby()
catching._catching_up = true
catching._server_restarting = true
check_seat(catching)
listener.data(100, {})
check(table.concat(calls, ',') == 'snapshot:true,resend,catching_up', 'the snapshot is handled as a rejoin: ' .. table.concat(calls, ','))
check(catching._server_restarting == nil, 'a restart notice is cleared by the rejoin')

-- not catching up: the flag is not sent
calls, in_match = {}, false
check_seat(seated_lobby())
listener.data(100, {})
check(table.concat(calls, ',') == 'snapshot:true,resend', 'no catching-up flag when not catching up')

-- the server refuses the old match and has the lobby under a new one: follow it, no teardown
joined, calls, in_match = {}, {}, false
local followed = seated_lobby()
check_seat(followed)
L.nakama_check_current = function(cb) cb({ matchId = 'match-2' }) end
join_cb('Match not found')
check(#joined == 2 and joined[2] == 'match-2', 'a refused reattach follows the seat to its new match')
check(followed._match_id == 'match-2', 'the lobby now names the new match')
check(#calls == 0, 'no teardown while following')

-- refused again on the new match: now it is over
join_cb('Match not found')
check(calls[1] == 'cleanup', 'a second refusal tears the lobby down')

-- the server has no seat to follow: torn down as a refused join
joined, calls, in_match = {}, {}, false
check_seat(seated_lobby())
L.nakama_check_current = function(cb) cb(nil) end
join_cb('Match not found')
check(#joined == 1 and calls[1] == 'cleanup', 'no seat to follow: the lobby is torn down')

T.done('reconnect_reattach_test')
