-- Contract test: L.cleanup lets go of the match only when the lobby owns it.
-- A late cleanup of an old or never-attached lobby must leave a newer lobby's
-- match, and L.current, alone. Run from the MPAPI repository root:
-- luajit tests/lobby_cleanup_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local match_id, forgets = nil, 0
MPAPI = {
	_internal = {},
	networking = {
		nakama_lobby = {
			forget = function()
				forgets = forgets + 1
				match_id = nil
			end,
			_current_match_id = function()
				return match_id
			end,
		},
	},
	chat = { cleanup = function() end },
	LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby

local A = { _nakama = true, _match_id = 'A' }
local B = { _nakama = true, _match_id = 'B' }

match_id, forgets, L.current = 'B', 0, B
L.cleanup(A)
check(forgets == 0 and match_id == 'B' and L.current == B, 'a stale cleanup leaves the newer match alone')

match_id, forgets, L.current = 'A', 0, A
L.cleanup({ _nakama = true, _match_id = 'A' })
check(forgets == 1 and match_id == nil, 'the lobby that owns the match forgets it')

match_id, forgets, L.current = 'B', 0, B
L.cleanup({ _nakama = true })
check(forgets == 0 and match_id == 'B' and L.current == B, 'a never-attached lobby leaves the match alone')

local C = { _nakama = true, _match_id = 'C' }
match_id, forgets, L.current = 'C', 0, C
L.cleanup(C)
check(forgets == 1 and L.current == nil, 'a normal cleanup forgets and clears the current lobby')

-- A put-off Run save belongs to the lobby the game is in: only its cleanup clears it.
local clears = 0
MPAPI.run_save = { clear_wait = function() clears = clears + 1 end }
local D = { _nakama = true, _match_id = 'D' }
match_id, L.current = 'D', D
L.cleanup({ _nakama = true, _match_id = 'A' })
check(clears == 0, 'a stale lobby cleaned up late leaves the current lobby\'s put-off save')
L.cleanup(D)
check(clears == 1, 'the current lobby clears its put-off save')

T.done('lobby_cleanup_test')
