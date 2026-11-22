-- Contract test: lobby:is_result_pending follows the server's pending result flag, from a
-- snapshot and from the live action result. Run from the MPAPI repository root:
-- luajit tests/result_pending_test.lua
local T = dofile('tests/support.lua')
local check = T.check

love = { timer = { getTime = function() return 0 end } }
local action_types = {}
local current
MPAPI = T.lobby_mpapi({
	ActionType = setmetatable({ obj_buffer = {} }, {
		__call = function(_, spec)
			action_types[spec.key] = spec
		end,
	}),
	get_current_lobby = function() return current end,
	set_player_ready = function() end,
})
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')

local function new_lobby()
	local lobby = L.create_object({})
	lobby._fire = function() end
	return lobby
end

local function snapshot(game)
	return { code = 'ABCD', hostId = 'a', players = {}, game = game }
end

current = new_lobby()
check(current:is_result_pending() == false, 'a new lobby is not pending')

L.apply_snapshot(current, snapshot({ resultPending = true, started = { runId = 'r1' } }), false)
check(current:is_result_pending() == true, 'a snapshot with the flag set reads as pending')

L.apply_snapshot(current, snapshot({ started = { runId = 'r1' } }), false)
check(current:is_result_pending() == false, 'a snapshot without the flag reads as not pending')

action_types.mpapi_set_result_pending.on_receive(nil, nil, { playerId = 'a', pending = true })
check(current:is_result_pending() == true, 'the live result sets the flag')
action_types.mpapi_set_result_pending.on_receive(nil, nil, { playerId = 'a', pending = false })
check(current:is_result_pending() == false, 'the live result clears the flag')

action_types.mpapi_set_result_pending.on_receive(nil, nil, { playerId = 'a', pending = true })
L.apply_game_ended(current, { runId = 'r1', status = 'agreed', placements = {} })
check(current:is_result_pending() == false, 'a finished game clears the flag')

T.done('result_pending_test')
