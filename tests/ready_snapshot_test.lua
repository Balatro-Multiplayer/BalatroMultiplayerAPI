-- Contract test: a snapshot is the whole truth about who is ready, so a player it does not
-- list as ready is told they are not (PLAYER_READY_CHANGED false). Run from the MPAPI
-- repository root: luajit tests/ready_snapshot_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

love = { timer = { getTime = function() return 0 end } }
local current
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, { __call = function() end }),
	ActionTypes = {},
	get_current_lobby = function()
		return current
	end,
	LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
	networking = { nakama_lobby = { set_grace_seconds = function() end } },
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/lobby/ready.lua')
dofile('api/action/builtin.lua')
dofile('api/lobby/nakama.lua')

local events = {}
current = L.create_object({})
current._fire = function(_, event, id, ready)
	events[#events + 1] = { event = event, id = id, ready = ready }
end

local function snapshot(ready)
	return {
		code = 'ABCD',
		hostId = 'a',
		players = { { id = 'a' }, { id = 'b' } },
		game = { ready = ready },
	}
end

L.apply_snapshot(current, snapshot({ a = true, b = true }), false)
check(current._players.a.ready == true and current._players.b.ready == true, 'both start ready')

events = {}
L.apply_snapshot(current, snapshot({ a = true }), false)
check(current._players.a.ready == true, 'a stays ready')
check(current._players.b.ready == false, 'b is no longer ready')
local told_b
for _, e in ipairs(events) do
	if e.event == 'PLAYER_READY_CHANGED' and e.id == 'b' then
		told_b = e.ready
	end
end
check(told_b == false, 'PLAYER_READY_CHANGED(b, false) fired')
check(current._game.ready.b == nil and current._game.ready.a == true, 'game.ready mirrors the snapshot')

-- Only a change is announced: the same snapshot again fires nothing.
events = {}
L.apply_snapshot(current, snapshot({ a = true }), false)
local ready_events = 0
for _, e in ipairs(events) do
	if e.event == 'PLAYER_READY_CHANGED' then
		ready_events = ready_events + 1
	end
end
check(ready_events == 0, 'an unchanged snapshot fires no PLAYER_READY_CHANGED')

-- A change to one player fires for that player only.
events = {}
L.apply_snapshot(current, snapshot({ a = true, b = true }), false)
local changed = {}
for _, e in ipairs(events) do
	if e.event == 'PLAYER_READY_CHANGED' then
		changed[#changed + 1] = e.id .. '=' .. tostring(e.ready)
	end
end
check(#changed == 1 and changed[1] == 'b=true', 'only the player who changed is announced')

-- A player seen for the first time is announced, ready or not.
events = {}
local with_c = snapshot({ a = true, b = true })
with_c.players[3] = { id = 'c' }
L.apply_snapshot(current, with_c, false)
local first_seen
for _, e in ipairs(events) do
	if e.event == 'PLAYER_READY_CHANGED' and e.id == 'c' then
		first_seen = e.ready
	end
end
check(first_seen == false, 'a first-seen player is announced with their ready value')
check(current._players.c.ready == false, 'a first-seen player is stored not ready')

events = {}
L.apply_snapshot(current, snapshot({ a = true, ghost = true }), false)
check(current._players.ghost == nil, 'an id outside the roster is not added')

print('ready_snapshot_test: ' .. checks .. ' checks passed')
