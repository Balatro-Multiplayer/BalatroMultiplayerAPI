-- Contract test for api/lobby/tutorial.lua: a lobby run never carries the base
-- game's tutorial (forced first shop, +$3 packs), a solo run is left alone.
-- Run from the MPAPI repository root: luajit tests/lobby_tutorial_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local lobby = nil
local seen = nil
MPAPI = {
	_internal = {},
	get_current_lobby = function()
		return lobby
	end,
}
G = { SETTINGS = {} }
Game = {
	start_run = function()
		seen = { complete = G.SETTINGS.tutorial_complete, progress = G.SETTINGS.tutorial_progress }
	end,
}
dofile('api/lobby/tutorial.lua')

-- A new profile mid-tutorial joins a lobby game.
G.SETTINGS = { tutorial_progress = { forced_shop = { 'j_joker', 'c_empress' }, completed_parts = {} } }
lobby = {}
Game.start_run(Game, {})
check(seen.complete == true, 'lobby run: tutorial counted as done before the run starts')
check(seen.progress == nil, 'lobby run: no tutorial progress, so no forced shop or +$3 packs')

-- The same profile outside a lobby keeps its tutorial.
local progress = { completed_parts = {} }
G.SETTINGS = { tutorial_progress = progress }
lobby = nil
Game.start_run(Game, {})
check(seen.complete == nil and seen.progress == progress, 'solo run: tutorial untouched')

local T = MPAPI._internal.tutorial
check(T.skip({ tutorial_complete = true }) == false, 'already done: nothing changes')
check(T.skip({ tutorial_complete = true, tutorial_progress = {} }) == true, 'done but progress left over: cleared')

print(('ok   %d checks'):format(checks))
