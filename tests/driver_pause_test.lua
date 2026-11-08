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

-- The checkpoint index fast-forwards to the end of the timeline. When the last entry's handler
-- pauses the driver, the tick after it resumes has nothing left to dispatch: the fast-forward
-- must still end (on_done) before the driver completes.
driver = build()
done = false
local completed = false
driver._on_complete = function()
	completed = true
end
MPAPI.playback.dispatch = function(_, opcode)
	if opcode == 3 then driver:pause() end
end
driver:fast_forward_to(4, {
	on_done = function()
		done = true
	end,
})
driver:_tick(0.016)
check(driver._cursor == 4, 'every entry was dispatched')
check(not done, 'the fast-forward waits for the paused last entry')
driver:play()
driver:_tick(0.016)
check(done, 'the fast-forward ends once the last entry resumes the driver')
check(completed, 'and the driver then completes')

-- Waits that gave up are counted for the rejoin's log.
MPAPI.playback.reset_gave_up_waits()
check(MPAPI.playback.gave_up_waits() == 0, 'the count starts at zero')
MPAPI.playback.record_gave_up_wait('[replay] a wait ran out')
MPAPI.playback.record_gave_up_wait('[replay] another wait ran out')
check(MPAPI.playback.gave_up_waits() == 2, 'each wait that gave up is counted')
MPAPI.playback.reset_gave_up_waits()
check(MPAPI.playback.gave_up_waits() == 0, 'a new catch-up starts at zero')

print('driver_pause_test: ' .. checks .. ' checks passed')
