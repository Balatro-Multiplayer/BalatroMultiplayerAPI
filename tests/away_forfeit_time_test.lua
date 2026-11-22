-- Contract test: an away player's forfeit time reaches the roster on this client's clock, from both
-- the snapshot and the player_disconnected event, and clears when they are back. Run from the MPAPI
-- repository root: luajit tests/away_forfeit_time_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local clock = 100
love = { timer = { getTime = function() return clock end } }
MPAPI = T.lobby_mpapi({ plain_letters = function(s) return s end })
dofile('api/lobby/state.lua')
dofile('api/lobby/ready.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')
dofile('api/lobby/events.lua')

local function new_lobby()
	local lobby = L.create_object({})
	lobby.player_id = 'a'
	lobby._players = { a = { id = 'a' }, b = { id = 'b' } }
	lobby.fired = {}
	lobby._fire = function(self, event, ...)
		self.fired[#self.fired + 1] = { event, ... }
	end
	return lobby
end

check(L.forfeit_local(nil, 5000) == nil, 'no forfeit time: nil')
check(L.forfeit_local(5000, nil) == nil, 'no server time: nil')
check(L.forfeit_local(65000, 5000) == 160, 'a minute ahead of the server now is a minute ahead locally')

-- The snapshot places it on the local clock; a present player has none.
local lobby = new_lobby()
L.apply_snapshot(lobby, {
	players = { { id = 'a', forfeitsAt = nil }, { id = 'b', isAway = true, forfeitsAt = 125000 } },
	hostId = 'a',
	game = {},
	serverNow = 5000,
}, true)
check(lobby._players.b.forfeits_at_local == 220, 'snapshot: the away player forfeits 120 s from now')
check(lobby._players.a.forfeits_at_local == nil, 'snapshot: a present player has none')

-- The event does the same and hands it to listeners.
lobby = new_lobby()
L.apply_event(lobby, {
	type = 'PLAYER_DISCONNECTED',
	playerId = 'b',
	data = { forfeitsAt = 125000, serverNow = 5000 },
})
check(lobby._players.b.forfeits_at_local == 220, 'event: the away player forfeits 120 s from now')
check(lobby.fired[1][1] == 'PLAYER_DISCONNECTED' and lobby.fired[1][2] == 'b' and lobby.fired[1][3] == 220, 'event: listeners get it')

L.apply_event(lobby, { type = 'PLAYER_RECONNECTED', playerId = 'b' })
check(lobby._players.b.forfeits_at_local == nil, 'back: the forfeit time is gone')

L.apply_event(lobby, { type = 'PLAYER_DISCONNECTED', playerId = 'b' })
check(lobby._players.b.forfeits_at_local == nil, 'an event naming no time leaves none')

-- A rejoin snapshot fires the away/back change for a player whose state flipped while we were down.
local function snapshot(b_away)
	return {
		players = { { id = 'a' }, { id = 'b', isAway = b_away, forfeitsAt = b_away and 125000 or nil } },
		hostId = 'a',
		game = {},
		serverNow = 5000,
	}
end
lobby = new_lobby()
L.apply_snapshot(lobby, snapshot(false), true)
lobby.fired = {}
L.apply_snapshot(lobby, snapshot(true), true)
local went_away
for _, f in ipairs(lobby.fired) do
	if f[1] == 'PLAYER_DISCONNECTED' then went_away = f end
end
check(went_away and went_away[2] == 'b' and went_away[3] == 220, 'rejoin: a player who dropped while we were down fires away with the time')
lobby.fired = {}
L.apply_snapshot(lobby, snapshot(true), true)
check(#lobby.fired == 0 or lobby.fired[1][1] ~= 'PLAYER_DISCONNECTED', 'rejoin: no change fires nothing')
L.apply_snapshot(lobby, snapshot(false), true)
local came_back
for _, f in ipairs(lobby.fired) do
	if f[1] == 'PLAYER_RECONNECTED' then came_back = f end
end
check(came_back and came_back[2] == 'b', 'rejoin: a player who returned while we were down fires back')
check(lobby._players.b.forfeits_at_local == nil, 'rejoin: their forfeit time is gone')

-- A held event is placed from when it arrived, not from when it is replayed.
lobby = new_lobby()
L.apply_event(lobby, {
	type = 'PLAYER_DISCONNECTED',
	playerId = 'b',
	received_local = 100,
	data = { forfeitsAt = 125000, serverNow = 5000 },
})
clock = 150
check(lobby._players.b.forfeits_at_local == 220, 'held: replay later does not move the forfeit time')

T.done('away_forfeit_time_test')
