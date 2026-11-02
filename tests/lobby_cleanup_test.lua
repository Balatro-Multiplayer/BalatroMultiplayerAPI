-- Contract test: L.cleanup lets go of the match only when the lobby owns it.
-- A late cleanup of an old or never-attached lobby must leave a newer lobby's
-- match, and L.current, alone. Run from the MPAPI repository root:
-- luajit tests/lobby_cleanup_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

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

print('ok ' .. checks .. ' checks')
