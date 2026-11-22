-- Contract test: after a connection teardown (MPAPI.reconnect) the current lobby is DROPPED, and a login
-- that then fails by any path into DISCONNECTED loses the lobby, once. disconnect() itself does not.
-- Run from the MPAPI repository root: luajit tests/connection_teardown_failure_test.lua
local T = dofile('tests/support.lua')
local check = T.check

love = { timer = { getTime = function() return 0 end } }
local in_match = false
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, { __call = function() end }),
	ActionTypes = {},
	get_current_lobby = function() end,
	ConnectionState = {
		DISCONNECTED = 'disconnected',
		CONNECTING = 'connecting',
		CONNECTED = 'connected',
		AUTHENTICATING = 'authenticating',
	},
	get_connection = function()
		return { get_state = function() return 'connected' end }
	end,
	get_nakama_session = function() return { user_id = 'me' } end,
	networking = {
		nakama_lobby = {
			ServerOp = { SNAPSHOT = 100 },
			set_grace_seconds = function() end,
			in_match = function() return in_match end,
			join = function() end,
			reset = function() in_match = false end,
		},
	},
	chat = { init = function() end, cleanup = function() end },
	is_forfeited_refusal = function() return false end,
	standing = { parse_rejoin_refusal = function() return nil end },
	set_player_ready = function() end,
	match_log = function() end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
	offline_reason_for_server_refusal = function() return 'refused' end,
	offline_reason_for_no_answer = function() return 'no answer' end,
}
dofile('domain/lobby_event.lua')
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')
dofile('networking/connection.lua')
L.apply_snapshot = function() end
L.resend_log_events = function() end
L.cleanup = function(lobby) lobby._destroyed = true end
local connection = MPAPI.networking.connection

-- A connection that tore down with a seated lobby: the lobby is DROPPED and no match is held.
local function after_teardown()
	in_match = false
	local lobby = L.nakama_join_match('mod', 'match1')
	lobby._nakama_ready = true
	L.current = lobby
	local fired = {}
	for _, name in ipairs({ 'CONNECTION_DROPPED', 'CONNECTION_RESTORED', 'DISCONNECTED' }) do
		lobby:on(MPAPI.LobbyEvent[name], function() fired[#fired + 1] = name end)
	end
	in_match = true
	local conn = connection.new({ config = {} })
	conn.state = 'connected'
	conn:disconnect()
	return conn, lobby, fired
end

local function login_fails(name, trigger)
	local conn, lobby, fired = after_teardown()
	check(table.concat(fired, ',') == 'CONNECTION_DROPPED', name .. ': disconnect() only drops: ' .. table.concat(fired, ','))
	conn.state = 'authenticating'
	trigger(conn)
	check(table.concat(fired, ',') == 'CONNECTION_DROPPED,DISCONNECTED', name .. ': one DISCONNECTED: ' .. table.concat(fired, ','))
	check(lobby._destroyed, name .. ': the lobby is gone')
end

login_fails('auth failed', function(conn) conn:_nakama_auth_failed(nil) end)
login_fails('login rejected', function(conn) conn:_login_refused('Nakama login rejected: ', 'no', 'refused', true) end)
login_fails('ToS declined', function(conn) conn:decline_tos() end)
login_fails('socket failed', function(conn)
	conn.state = 'connecting'
	MPAPI.networking.nakama_lobby.keep_socket_open = function() end
	MPAPI.networking.nakama_lobby.ensure_socket = function(cb) cb(false, 'down') end
	conn:_nakama_connect()
end)

-- A drop the connection never saw (the socket's own) is not touched by a state change.
local conn, lobby, fired = after_teardown()
conn.state = 'connected'
L.nakama_reattach(lobby)
check(not lobby._destroyed, 'a lobby awaiting its reattach is not lost by disconnect()')

T.done('connection_teardown_failure_test')
