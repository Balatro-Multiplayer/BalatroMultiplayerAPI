-- A snapshot's game.lastEnded says how the viewer's last game ended: it is raised as GAME_ENDED once
-- per run, with the server's status, and nothing is raised (or made up) when the server says nothing.
-- Run from the MPAPI repository root: luajit tests/last_ended_test.lua
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

local ended
current = L.create_object({})
current._fire = function(_, event, data)
	if event == 'GAME_ENDED' then
		ended[#ended + 1] = data
	end
end

local function snapshot(game)
	return { code = 'ABCD', hostId = 'a', players = { { id = 'a' } }, game = game }
end

-- Started, then the snapshot after the game ended says how.
current._game.started = { run_id = 'r1' }
ended = {}
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r1', status = 'dodged' } }), true)
check(#ended == 1, 'the end is raised')
check(ended[1].status == 'dodged' and ended[1].run_id == 'r1', 'with the server status and run')
check(ended[1].while_away == true, 'marked as learned while away')

-- The same snapshot again: once per run.
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r1', status = 'dodged' } }), true)
check(#ended == 1, 'not raised twice')

-- A new run's end is raised.
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r2', status = 'agreed' } }), true)
check(#ended == 2 and ended[2].status == 'agreed', 'a new run is raised')

-- null: nothing is raised, even when the game was started here (no made up status).
current._game.started = { run_id = 'r3' }
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = nil }), true)
check(#ended == 2, 'no lastEnded raises nothing')

-- Malformed entries raise nothing.
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { status = 'dodged' } }), true)
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r4' } }), true)
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = 'dodged' }), true)
check(#ended == 2, 'malformed lastEnded raises nothing')

-- A live GAME_ENDED counts as seen: the next snapshot does not repeat it.
L.apply_game_ended(current, { runId = 'r5', status = 'agreed', placements = {} })
check(#ended == 3 and ended[3].while_away == false, 'a live end is not marked away')
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r5', status = 'agreed' } }), true)
check(#ended == 3, 'the snapshot does not repeat a live end')

-- The first snapshot of a join is not announced: its end waits until the lobby is connected (the
-- mod listens then), and is raised once.
current._pending_ended = nil
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r6', status = 'dodged' } }), false)
check(#ended == 3, 'an unannounced snapshot raises nothing yet')
L.raise_pending_ended(current)
check(#ended == 4 and ended[4].run_id == 'r6' and ended[4].status == 'dodged', 'raised once the lobby is connected')
check(ended[4].while_away == true, 'marked as learned while away')
L.raise_pending_ended(current)
check(#ended == 4, 'not raised twice')
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r6', status = 'dodged' } }), true)
check(#ended == 4, 'a later snapshot does not repeat it')

-- An end already seen live is not held for later.
L.apply_snapshot(current, snapshot({ ready = {}, lastEnded = { runId = 'r5', status = 'agreed' } }), false)
L.raise_pending_ended(current)
check(#ended == 4, 'a seen run is not pending')

-- A join whose lobby is destroyed before connected() never showed the end: the next join still
-- raises it, once. The run counts as seen only when it is actually raised.
local first = L.create_object({})
first._fire = current._fire
L.apply_snapshot(first, snapshot({ ready = {}, lastEnded = { runId = 'r7', status = 'dodged' } }), false)
first._destroyed = true
L.raise_pending_ended(first)
check(#ended == 4, 'a destroyed lobby raises nothing')
local second = L.create_object({})
second._fire = current._fire
L.apply_snapshot(second, snapshot({ ready = {}, lastEnded = { runId = 'r7', status = 'dodged' } }), false)
L.raise_pending_ended(second)
check(#ended == 5 and ended[5].run_id == 'r7', 'the next join raises it')
L.raise_pending_ended(second)
check(#ended == 5, 'once')

-- connected() (every join path: create, join, match, rejoin, attach_detached) raises the held end
-- after CONNECTED fired.
local nl = string.char(10)
local file = assert(io.open('api/lobby/nakama.lua', 'rb'))
local text = file:read('*a'):gsub(string.char(13) .. nl, nl)
file:close()
local body = assert(text:match(nl .. 'local function connected%(lobby, on_ready%).-' .. nl .. 'end' .. nl), 'connected not found')
check(body:find('CONNECTED', 1, true) < body:find('L.raise_pending_ended(lobby)', 1, true), 'raised after CONNECTED')

-- A rejoin after a relaunch (the Reconnect prompt) only gets its GAME_ENDED listener in on_ready,
-- where the mod builds its lobby mirror: the held end is raised after on_ready, not before.
local on_ready_at = body:find('on_ready(lobby)', 1, true)
check(on_ready_at and on_ready_at < body:find('L.raise_pending_ended(lobby)', 1, true), 'raised after on_ready')
local rejoin = assert(text:match(nl .. 'L.nakama_rejoin_lobby = function.-' .. nl .. 'end' .. nl), 'rejoin not found')
check(rejoin:find('connected(l, on_ready)', 1, true), 'the rejoin hands on_ready to connected')

print(('last_ended_test: %d checks passed'):format(checks))
