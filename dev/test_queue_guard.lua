-- Standalone regression test for api/matchmaking/run_guard.lua's queue-blocks-
-- run-start gate. Not wired into a test framework (the repo has none) -- this
-- is a self-contained LuaJIT script that stubs just enough of the Balatro/
-- MPAPI surface (G.FUNCS, G.SETTINGS, MPAPI.matchmaking.is_queued,
-- MPAPI.queue_guard_overlay) to load and drive the real module source.
--
-- Run: luajit dev/test_queue_guard.lua

local this_dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local SRC_PATH = this_dir .. '../api/matchmaking/run_guard.lua'

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local content = f:read('*a')
	f:close()
	return content
end

local fixed_src = read_file(SRC_PATH)

-- The "broken" control variant reproduces the pre-fix behaviour (no gate at
-- all -- G.FUNCS.start_run falls straight through to the original), so the
-- regression test can prove it would actually have failed before the fix.
local GATE_BLOCK = [[
	if MPAPI.matchmaking.is_queued() then
		-- Stash the blocked action so the overlay's "Leave Queue & Play" can
		-- replay it after leaving. Replay goes back through this wrapper, so the
		-- gate is re-checked -- if the leave somehow didn't take, it re-blocks
		-- instead of starting a run while queued.
		mm.pending_run = { e = e, args = args }
		G.SETTINGS.paused = true
		MPAPI.queue_guard_overlay:as_overlay()
		return
	end
]]

local function strip_exact(src, needle)
	local s, e = src:find(needle, 1, true) -- plain (non-pattern) find
	assert(s, 'failed to construct pre-fix control variant (gate block not found verbatim)')
	return src:sub(1, s - 1) .. src:sub(e + 1)
end

local broken_src = strip_exact(fixed_src, GATE_BLOCK)
assert(broken_src ~= fixed_src, 'control variant did not change source')

-------------------------------------------------------------------
-- Fake environment: G.FUNCS, G.SETTINGS, MPAPI
-------------------------------------------------------------------

local function make_env()
	local original_start_run_calls = 0
	local overlay_shown_count = 0
	local _searching = false

	local G = {
		FUNCS = {
			-- Stand-in for the vanilla G.FUNCS.start_run this module wraps.
			start_run = function(_e, _args)
				original_start_run_calls = original_start_run_calls + 1
			end,
		},
		SETTINGS = { paused = false },
	}

	local MPAPI = {
		_internal = {},
		matchmaking = {
			is_queued = function() return _searching end,
		},
		queue_guard_overlay = {
			as_overlay = function() overlay_shown_count = overlay_shown_count + 1 end,
		},
	}

	return {
		G = G,
		MPAPI = MPAPI,
		set_searching = function(v) _searching = v end,
		start_run_calls = function() return original_start_run_calls end,
		overlay_shown_count = function() return overlay_shown_count end,
		call_start_run = function() G.FUNCS.start_run(nil, {}) end,
	}
end

local function load_module(src, env)
	local chunk_env = setmetatable({ G = env.G, MPAPI = env.MPAPI }, { __index = _G })
	local chunk = assert(loadstring(src, 'run_guard'))
	setfenv(chunk, chunk_env)
	chunk()
end

------------------------
-- Test harness
------------------------

local failures = 0
local function check(cond, msg)
	if cond then
		print('PASS: ' .. msg)
	else
		failures = failures + 1
		print('FAIL: ' .. msg)
	end
end

------------------------
-- Test 1 (fixed): not searching -> start_run proceeds untouched (zero overhead)
------------------------

print()
print('-- scenario: fixed run_guard.lua, not searching --')
local env2 = make_env()
load_module(fixed_src, env2)
env2.set_searching(false)
env2.call_start_run()
check(env2.start_run_calls() == 1, 'fixed: original start_run called when not searching')
check(env2.overlay_shown_count() == 0, 'fixed: guard overlay not shown when not searching')

------------------------
-- Test 3 (fixed): searching -> start_run blocked, overlay shown instead
------------------------

print()
print('-- scenario: fixed run_guard.lua, searching --')
local env3 = make_env()
load_module(fixed_src, env3)
env3.set_searching(true)
env3.call_start_run()
check(env3.start_run_calls() == 0, 'fixed: original start_run NOT called while searching')
check(env3.overlay_shown_count() == 1, 'fixed: guard overlay shown while searching')

------------------------
-- Test 4 (fixed): leave-queue-then-allow sequence
------------------------

print()
print('-- scenario: fixed run_guard.lua, leave queue then retry --')
local env4 = make_env()
load_module(fixed_src, env4)
env4.set_searching(true)
env4.call_start_run()
check(env4.start_run_calls() == 0, 'leave-then-allow: blocked while still searching')
check(env4.overlay_shown_count() == 1, 'leave-then-allow: overlay shown while still searching')

-- Simulate "Leave Queue": the handle leaves, is_queued() flips false.
env4.set_searching(false)
env4.call_start_run()
check(env4.start_run_calls() == 1, 'leave-then-allow: start_run proceeds once no longer searching')

------------------------
-- Test 5 (fixed): "Leave Queue & Play" -- blocked action is stashed and can be
-- replayed through the gate once no longer searching
------------------------

print()
print('-- scenario: fixed run_guard.lua, leave queue and play (stash + replay) --')
local env5 = make_env()
load_module(fixed_src, env5)
env5.set_searching(true)
local marker_args = { tag = 'replay-me' }
env5.G.FUNCS.start_run(nil, marker_args)
local mm5 = env5.MPAPI._internal.mm
check(env5.start_run_calls() == 0, 'leave-and-play: blocked while searching')
check(mm5.pending_run ~= nil and mm5.pending_run.args == marker_args, 'leave-and-play: blocked action stashed with its original args')

-- Simulate the overlay button: leave queue (is_queued flips false), replay.
env5.set_searching(false)
local pending = mm5.pending_run
mm5.pending_run = nil
env5.G.FUNCS.start_run(pending.e, pending.args)
check(env5.start_run_calls() == 1, 'leave-and-play: replayed action proceeds after leaving')

-- Replay must re-check the gate: if still searching, it re-blocks.
local env5b = make_env()
load_module(fixed_src, env5b)
env5b.set_searching(true)
env5b.call_start_run()
local mm5b = env5b.MPAPI._internal.mm
local pending_b = mm5b.pending_run
env5b.G.FUNCS.start_run(pending_b.e, pending_b.args) -- still searching
check(env5b.start_run_calls() == 0, 'leave-and-play: replay while STILL searching re-blocks (no run starts queued)')

------------------------
-- Test 6: handle:leave() fires the "left" event exactly once
------------------------

print()
print('-- scenario: matchmaking handle fires left on leave() --')
local HANDLE_SRC = read_file(this_dir .. '../api/matchmaking/handle.lua')
local handle_MPAPI = {
	matchmaking = {},
	_internal = { mm = { remove_handle = function() end } },
	get_connection = function() return nil end,
	sendWarnMessage = function() end,
}
local handle_chunk = assert(loadstring(HANDLE_SRC, 'handle'))
setfenv(handle_chunk, setmetatable({ MPAPI = handle_MPAPI }, { __index = _G }))
handle_chunk()

local h = handle_MPAPI.matchmaking._make_handle('TestMod', 'test_mode')
local left_fired = 0
h:on('left', function() left_fired = left_fired + 1 end)
h:leave()
check(left_fired == 1, 'handle: left event fired on leave()')
h:leave()
check(left_fired == 1, 'handle: left event NOT re-fired on a duplicate leave()')

------------------------
-- Test 7 (RED control): pre-fix source has no gate -- run starts while searching
------------------------

print()
print('-- scenario: pre-fix run_guard.lua (control, proves the test is meaningful) --')
local broken_env = make_env()
load_module(broken_src, broken_env)
broken_env.set_searching(true)
broken_env.call_start_run()
check(broken_env.start_run_calls() == 1, 'broken: (control) start_run proceeds even while searching -- reproduces the bug')
check(broken_env.overlay_shown_count() == 0, 'broken: (control) no guard overlay ever shown')

------------------------

print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
