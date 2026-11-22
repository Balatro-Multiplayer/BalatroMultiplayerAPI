-- Contract test for the startup Ranked-verification gate's state machine.
-- Run from the MPAPI repository root:
-- luajit tests/verify_gate_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local Gate = dofile('anticheat/verify_gate.lua')
local S = Gate.State

local clock = 0
local log
local function new_gate()
	clock = 0
	log = {}
	return Gate.new({
		window = 5,
		now = function() return clock end,
		hooks = {
			on_attempt = function(n) log[#log + 1] = 'attempt:' .. n end,
			on_done = function(s) log[#log + 1] = 'done:' .. s end,
			on_bypass = function() log[#log + 1] = 'bypass' end,
		},
	})
end
local function trace() return table.concat(log, ',') end

-- Verified inside the window: no prompt, overlay cleared.
local g = new_gate()
g:start()
check(g.state == S.VERIFYING and g:is_blocking(), 'start blocks')
clock = 4.9
g:tick()
check(g.state == S.VERIFYING, 'still inside the window')
check(g:verified() == true, 'verdict counts')
check(trace() == 'done:verified', 'verified inside window: ' .. trace())
check(not g:is_blocking(), 'verified unblocks')
clock = 99
g:tick()
check(g.state == S.VERIFIED, 'verified is terminal')

-- Window runs out: prompt once, not every frame.
g = new_gate()
g:start()
clock = 5
g:tick()
g:tick()
check(g.state == S.PROMPTING and g:is_blocking(), 'prompt blocks')
check(trace() == '', 'the window running out fires no hook: ' .. trace())

-- Keep waiting: fresh attempt, fresh window measured from now.
clock = 8
g:keep_waiting()
check(g.state == S.VERIFYING and g.attempts == 2, 'fresh attempt')
check(trace() == 'attempt:2', 'keep waiting: ' .. trace())
clock = 12.9
g:tick()
check(g.state == S.VERIFYING, 'new window starts at the retry, not at launch')
clock = 13
g:tick()
check(g.state == S.PROMPTING, 'second window expires')

-- Verdict arriving while the prompt is up still counts and clears it.
check(g:verified() == true, 'late verdict before bypass counts')
check(g.state == S.VERIFIED and trace():match('done:verified$'), 'prompt cleared')

-- Give up: irreversible, and a later verdict is rejected.
g = new_gate()
g:start()
clock = 6
g:tick()
g:bypass()
check(g.state == S.BYPASSED and g:is_bypassed(), 'bypassed')
check(trace() == 'bypass,done:bypassed', 'bypass: ' .. trace())
check(g:verified() == false, 'late verdict rejected after bypass')
check(g.state == S.BYPASSED, 'stays bypassed')
g:keep_waiting()
g:start()
check(g.state == S.BYPASSED, 'cannot leave bypassed')
check(not g:is_blocking(), 'bypassed does not block')

-- Giving up is also allowed while still inside a window (hook for future UI).
g = new_gate()
g:start()
g:bypass()
check(g.state == S.BYPASSED, 'bypass mid-attempt')

-- A verdict that beats the main menu: gate never opens.
g = new_gate()
check(g:verified() == true, 'early verdict counts')
g:start()
check(g.state == S.VERIFIED and trace() == '', 'no overlay when already verified: ' .. trace())

-- A definite failure goes to the prompt at once, and only from a window.
g = new_gate()
g:start()
g:failed()
check(g.state == S.PROMPTING and g:is_blocking(), 'failed verdict asks at once')
g:keep_waiting()
check(g.state == S.VERIFYING and g.attempts == 2, 'keep waiting after a failed verdict')
g:bypass()
g:failed()
check(g.state == S.BYPASSED, 'failed does not undo a bypass')
g = new_gate()
g:failed()
check(g.state == S.IDLE, 'failed before the gate opens does nothing')

-- keep_waiting outside the prompt does nothing.
g = new_gate()
g:start()
g:keep_waiting()
check(g.attempts == 1, 'keep_waiting only from the prompt')

T.done('verify_gate_test')
