-- Contract test: a fast-forward does not end while a handler has paused the driver.
-- Run from the MPAPI repository root: luajit tests/driver_pause_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

G = { CONTROLLER = { locks = {} }, SETTINGS = { GAMESPEED = 1 }, FUNCS = { go_to_menu = function() end } }
Game = { update = function() end }
MPAPI = {
	load_mpapi_file = function() end,
	replay = { SCHEMA_VERSION = 1, new_resolver_state = function() return {} end },
	sendWarnMessage = function() end,
	playback = { dispatch = function() end },
}
dofile('api/playback/driver.lua')

-- A handler that waits on its action pauses the driver in the dispatch of the last entry
-- before the fast-forward target; the rejoin's on_done then starts the driver.
local function build()
	local timeline = {}
	for i = 1, 3 do timeline[i] = { opcode = i, player_id = 'p', args = {} } end
	local driver = MPAPI.playback.new_driver(timeline, { mod_id = 'pvp' })
	driver:finish()
	return driver
end

local driver = build()
local done = false
MPAPI.playback.dispatch = function(_, opcode)
	if opcode == 2 then driver:pause() end
end
driver:fast_forward_to(3, {
	on_done = function()
		done = true
		driver:play()
	end,
})
driver:_tick(0.016)
check(driver._cursor == 3, 'the fast-forward reached its target')
check(not driver:is_playing(), 'the handler pause holds')
check(not done, 'the fast-forward does not end while the driver is paused')

-- The handler resumes the driver once its action applied.
driver:play()
driver:_tick(0.016)
check(done, 'the fast-forward ends once the driver is resumed')
check(driver:is_playing(), 'the driver plays on')

print('driver_pause_test: ' .. checks .. ' checks passed')
