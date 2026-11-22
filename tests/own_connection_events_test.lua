-- Contract test: a lobby tells its listeners once when this client's own socket drops and once when
-- the seat is back (a rejoin, or a reattach after a connection teardown), so a mod can hold its game
-- meanwhile. A drop that ends in the lobby being lost gives DISCONNECTED and no return.
-- Run from the MPAPI repository root: luajit tests/own_connection_events_test.lua
local T = dofile('tests/support.lua')
local check = T.check

love = { timer = { getTime = function() return 0 end } }
local joins = {}
local in_match = false
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, { __call = function() end }),
	ActionTypes = {},
	get_current_lobby = function() end,
	ConnectionState = { CONNECTED = 'connected' },
	get_connection = function()
		return { get_state = function() return 'connected' end }
	end,
	get_nakama_session = function() return { user_id = 'me' } end,
	networking = {
		nakama_lobby = {
			ServerOp = { SNAPSHOT = 100 },
			set_grace_seconds = function() end,
			in_match = function() return in_match end,
			join = function(match_id, _, listener)
				joins[#joins + 1] = { match_id = match_id, listener = listener }
			end,
		},
	},
	chat = { init = function() end, cleanup = function() end },
	is_forfeited_refusal = function() return false end,
	standing = { parse_rejoin_refusal = function() return nil end },
	set_player_ready = function() end,
	match_log = function() end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('domain/lobby_event.lua')
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')
L.apply_snapshot = function() end
L.resend_log_events = function() end
L.cleanup = function(lobby) lobby._destroyed = true end

-- A seated lobby (first snapshot in) that records the connection events it fires.
local function seated_lobby()
	joins = {}
	in_match = false
	local lobby = L.nakama_join_match('mod', 'match1')
	lobby._nakama_ready = true
	local fired = {}
	for _, name in ipairs({ 'CONNECTION_DROPPED', 'CONNECTION_RESTORED', 'DISCONNECTED' }) do
		lobby:on(MPAPI.LobbyEvent[name], function() fired[#fired + 1] = name end)
	end
	return lobby, fired, joins[1].listener
end

-- A drop, then the transport's own rejoin: one event each, whichever of the snapshot and the
-- rejoined notice comes first.
local lobby, fired, listener = seated_lobby()
listener.dropped()
listener.rejoined()
listener.data(100, {})
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED', 'a drop and its rejoin fire once each: ' .. table.concat(fired, ','))

lobby, fired, listener = seated_lobby()
listener.dropped()
listener.data(100, {})
listener.rejoined()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED', 'the snapshot first: still once each: ' .. table.concat(fired, ','))

-- A drop, then a connection teardown and a fresh join (reattach): the seat coming back fires the return.
lobby, fired, listener = seated_lobby()
listener.dropped()
check(L.nakama_reattach(lobby), 'the lobby is reattached')
check(#joins == 2 and joins[2].match_id == 'match1', 'the reattach joins the lobby\'s own match')
joins[2].listener.data(100, {})
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED', 'a reattach after a drop fires the return once: ' .. table.concat(fired, ','))
joins[2].listener.rejoined()
check(#fired == 2, 'a later rejoined notice adds nothing')

-- A reattach with no drop before it fires nothing.
lobby, fired, listener = seated_lobby()
L.nakama_reattach(lobby)
joins[2].listener.data(100, {})
check(#fired == 0, 'no drop, no return')

-- A drop that ends in the lobby being lost: DISCONNECTED, and no return.
lobby, fired, listener = seated_lobby()
listener.dropped()
listener.lost('gone', true)
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,DISCONNECTED', 'a lost lobby gives DISCONNECTED and no return: ' .. table.concat(fired, ','))

-- Two drops: two returns.
lobby, fired, listener = seated_lobby()
listener.dropped()
listener.rejoined()
listener.dropped()
listener.rejoined()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED,CONNECTION_DROPPED,CONNECTION_RESTORED', 'two drops give two returns: ' .. table.concat(fired, ','))

-- A connection teardown releases the held match: the seated current lobby is DROPPED (once), and
-- when the login after it fails the lobby is lost, so DISCONNECTED follows.
lobby, fired, listener = seated_lobby()
L.current = lobby
L.nakama_match_released()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED', 'a teardown drops the seated lobby: ' .. table.concat(fired, ','))
L.nakama_match_released()
check(#fired == 1, 'a second teardown does not drop it twice')
L.nakama_connection_failed()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,DISCONNECTED', 'a failed login ends the drop with DISCONNECTED: ' .. table.concat(fired, ','))

-- A teardown and a login that comes back: the reattach fires the return, a failure hook adds nothing.
lobby, fired, listener = seated_lobby()
L.current = lobby
L.nakama_match_released()
in_match = false
L.nakama_reattach(lobby)
joins[2].listener.data(100, {})
L.nakama_connection_failed()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED', 'a drop that comes back is not torn down: ' .. table.concat(fired, ','))

-- A failed login with no drop before it leaves the lobby alone.
lobby, fired, listener = seated_lobby()
L.current = lobby
L.nakama_connection_failed()
check(#fired == 0 and not lobby._destroyed, 'no drop, nothing lost')

-- A teardown while the first join is still in flight: the lobby cannot be seated, so it is lost.
joins = {}
in_match = false
lobby = L.nakama_join_match('mod', 'match2')
fired = {}
lobby:on(MPAPI.LobbyEvent.DISCONNECTED, function() fired[#fired + 1] = 'DISCONNECTED' end)
L.nakama_match_released()
check(#fired == 1 and lobby._destroyed, 'a teardown during the first join loses the lobby')

-- A teardown drops the seat, then the old socket reports its own drop: one CONNECTION_DROPPED.
lobby, fired, listener = seated_lobby()
L.current = lobby
L.nakama_match_released()
listener.dropped()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED', 'a teardown and a socket drop fire one drop: ' .. table.concat(fired, ','))
listener.rejoined()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED', 'the seat still returns after the guarded drop: ' .. table.concat(fired, ','))
listener.dropped()
check(table.concat(fired, ',') == 'CONNECTION_DROPPED,CONNECTION_RESTORED,CONNECTION_DROPPED', 'the next drop fires again: ' .. table.concat(fired, ','))

T.done('own_connection_events_test')
