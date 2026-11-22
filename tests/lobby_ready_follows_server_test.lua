-- Contract test: the Ready shown for a player is what the server's lobby state last said. A game
-- starting or ending clears it, and a snapshot sets exactly its own list. Run from the MPAPI
-- repository root: luajit tests/lobby_ready_follows_server_test.lua
local T = dofile('tests/support.lua')
local check = T.check

love = { timer = { getTime = function() return 0 end } }
local current
MPAPI = T.lobby_mpapi({
	get_current_lobby = function() return current end,
	plain_letters = function(s) return s end,
})
dofile('api/lobby/state.lua')
dofile('api/lobby/ready.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')

local function new_lobby()
	local lobby = L.create_object({})
	lobby.player_id = 'a'
	lobby._players = { a = { id = 'a' }, b = { id = 'b' }, c = { id = 'c' } }
	lobby.fired = {}
	lobby._fire = function(self, event, ...)
		if event == 'PLAYER_READY_CHANGED' then
			self.fired[#self.fired + 1] = { ... }
		end
	end
	current = lobby
	return lobby
end

local function ready_of(lobby, id)
	return lobby._players[id].ready == true
end

-- A game ending clears every shown Ready and fires once per player who was ready.
local lobby = new_lobby()
MPAPI.set_player_ready(lobby, 'a', true)
MPAPI.set_player_ready(lobby, 'b', true)
lobby.fired = {}
L.apply_game_ended(lobby, { runId = 'r1', status = 'agreed', placements = {} })
check(not ready_of(lobby, 'a') and not ready_of(lobby, 'b'), 'game end clears shown Ready')
check(#lobby.fired == 2, 'game end fires once per player whose Ready changed')
for _, call in ipairs(lobby.fired) do
	check(call[2] == false, 'the event carries the new value')
end

-- A game starting clears them too.
lobby = new_lobby()
MPAPI.set_player_ready(lobby, 'b', true)
lobby.fired = {}
L.apply_game_started(lobby, { runId = 'r2', seed = 's', players = {} })
check(not ready_of(lobby, 'b'), 'game start clears shown Ready')
check(#lobby.fired == 1 and lobby.fired[1][1] == 'b', 'game start fires for the one player who changed')

-- A snapshot sets exactly its own list: a player it no longer lists is not ready.
lobby = new_lobby()
MPAPI.set_player_ready(lobby, 'b', true)
MPAPI.set_player_ready(lobby, 'c', true)
lobby.fired = {}
L.apply_snapshot(lobby, {
	players = { { id = 'a' }, { id = 'b' }, { id = 'c' } },
	hostId = 'a',
	game = { ready = { c = true, b = false } },
}, true)
check(not ready_of(lobby, 'b'), 'snapshot clears a player it lists as not ready')
check(ready_of(lobby, 'c'), 'snapshot keeps a player it lists as ready')
check(not ready_of(lobby, 'a'), 'snapshot leaves a player it does not list not ready')
check(#lobby.fired == 1 and lobby.fired[1][1] == 'b', 'snapshot fires only for the player whose value changed')

-- A snapshot with no ready list at all clears everyone.
lobby = new_lobby()
MPAPI.set_player_ready(lobby, 'a', true)
L.apply_snapshot(lobby, { players = { { id = 'a' }, { id = 'b' } }, hostId = 'a', game = {} }, true)
check(not ready_of(lobby, 'a'), 'snapshot without a ready list clears Ready')

-- A rejoin snapshot with a new player who is ready: the player joins before the Ready event.
lobby = new_lobby()
lobby._players = { a = { id = 'a' } }
local order = {}
lobby._fire = function(_, event, id)
	if event == 'PLAYER_JOINED' or event == 'PLAYER_READY_CHANGED' then
		order[#order + 1] = event .. ':' .. tostring(id)
	end
end
L.apply_snapshot(lobby, {
	players = { { id = 'a' }, { id = 'd' } },
	hostId = 'a',
	game = { ready = { d = true } },
}, true)
check(table.concat(order, ',') == 'PLAYER_JOINED:d,PLAYER_READY_CHANGED:d', 'the join comes before the Ready event: ' .. table.concat(order, ','))
check(ready_of(lobby, 'd'), 'and the new player is shown ready')

T.done('lobby_ready_follows_server_test')
