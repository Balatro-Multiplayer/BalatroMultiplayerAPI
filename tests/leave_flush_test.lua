-- Contract test: lobby:leave sends the log events recorded this frame before it
-- tells the server it leaves. Run from the MPAPI repository root:
-- luajit tests/leave_flush_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

package.preload['json'] = function() return dofile('lib/nakama/util/json.lua') end
love = { timer = { getTime = function() return 0 end } }
local order = {}
local queued = {}
G = { E_MANAGER = { add_event = function(_, event) queued[#queued + 1] = event end } }
Event = function(spec) return spec end
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, {
		__call = function() end,
	}),
	ActionTypes = { mpapi_log_event = {}, mpapi_log_events = {} },
	get_current_lobby = function() end,
	LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
	networking = {
		nakama_lobby = {
			set_grace_seconds = function() end,
			leave = function() order[#order + 1] = 'leave' end,
		},
	},
	set_player_ready = function() end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')

local lobby = L.create_object({})
lobby._game = { started = { run_id = 'r1' } }
lobby.action = function()
	return {
		send = function(_, _, payload)
			order[#order + 1] = payload.events and ('batch:' .. #payload.events) or ('event:' .. payload.t)
			return true
		end,
	}
end

L.send_log_event(lobby, 'END', 1)
L.send_log_event(lobby, 'CHK', 2)
check(#order == 0, 'events wait for the end of the frame')

lobby:leave()
check(order[1] == 'batch:2', 'the events go out before the leave, got ' .. tostring(order[1]))
check(order[2] == 'leave', 'the leave follows the events, got ' .. tostring(order[2]))
check(lobby._unsent_log_events == nil, 'nothing stays kept')

lobby:leave()
check(#order == 2, 'a second leave sends nothing more')

queued[1].func()
check(#order == 2, 'the end-of-frame flush finds nothing to send')

print(('ok   %d checks'):format(checks))
