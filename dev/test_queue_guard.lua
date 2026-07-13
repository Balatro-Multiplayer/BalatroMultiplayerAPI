-- Standalone regression test for the matchmaking queue guard
-- (api/matchmaking/queue_guard.lua): the shared guard_queued() gate and its
-- application to singleplayer run-start. Not wired into a test framework (the
-- repo has none) -- this is a self-contained LuaJIT script that stubs just
-- enough of the Balatro/MPAPI surface to load and drive the real module source.
--
-- Consumer mods reuse guard_queued() for their own queue-conflicting actions
-- (e.g. lobby create/join); those live in the consumer repos and are tested
-- there -- each must replay its OWN complete entry point (see guard_queued's
-- note), which is why the gate is not applied to MPAPI.join_lobby here.
--
-- Run: luajit dev/test_queue_guard.lua

local this_dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
local GUARD_PATH = this_dir .. '../api/matchmaking/queue_guard.lua'

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local content = f:read('*a')
	f:close()
	return content
end

local function strip_exact(src, needle)
	local s, e = src:find(needle, 1, true) -- plain (non-pattern) find
	assert(s, 'failed to construct pre-fix control variant (block not found verbatim)')
	return src:sub(1, s - 1) .. src:sub(e + 1)
end

local guard_src = read_file(GUARD_PATH)

-- The "broken" control variant of the run gate reproduces the pre-fix behaviour
-- (no gate at all -- G.FUNCS.start_run falls straight through to the original),
-- so the regression test can prove it would actually have failed before the fix.
local RUN_GATE_BLOCK = [[
	-- The replay closure re-enters the wrapper (not _start_run_ref) so the gate
	-- re-checks on the way through, matching the lobby entry points.
	if MPAPI.matchmaking.guard_queued(function() return G.FUNCS.start_run(e, args) end) then
		return
	end
]]

local broken_guard_src = strip_exact(guard_src, RUN_GATE_BLOCK)
assert(broken_guard_src ~= guard_src, 'run-gate control variant did not change source')

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

local function load_chunk(src, name, env)
	local chunk = assert(loadstring(src, name))
	setfenv(chunk, setmetatable(env, { __index = _G }))
	chunk()
end

-------------------------------------------------------------------
-- Fake environment: G.FUNCS, G.SETTINGS, MPAPI
-------------------------------------------------------------------

local function make_env()
	local original_start_run_calls = 0
	local last_start_run_args = nil
	local overlay_shown_count = 0
	local _searching = false

	local G = {
		FUNCS = {
			-- Stand-in for the vanilla G.FUNCS.start_run this module wraps.
			start_run = function(_e, _args)
				original_start_run_calls = original_start_run_calls + 1
				last_start_run_args = _args
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
		last_start_run_args = function() return last_start_run_args end,
		overlay_shown_count = function() return overlay_shown_count end,
		call_start_run = function() G.FUNCS.start_run(nil, {}) end,
	}
end

local function load_guard(src, env)
	load_chunk(src, 'queue_guard', { G = env.G, MPAPI = env.MPAPI })
end

------------------------
-- guard_queued: the shared gate contract used by run-start and consumers
------------------------

print()
print('-- guard_queued: not searching -> proceeds, no side effects --')
local envg = make_env()
load_guard(guard_src, envg)
envg.set_searching(false)
local replays = 0
local blocked = envg.MPAPI.matchmaking.guard_queued(function() replays = replays + 1 end)
check(blocked == false, 'guard_queued returns false when not searching (caller proceeds)')
check(envg.overlay_shown_count() == 0, 'guard_queued shows no overlay when not searching')
check(envg.MPAPI._internal.mm.pending_action == nil, 'guard_queued stashes nothing when not searching')

print()
print('-- guard_queued: searching -> blocks, stashes the replay, shows overlay --')
local envg2 = make_env()
load_guard(guard_src, envg2)
envg2.set_searching(true)
local sentinel = function() end
local blocked2 = envg2.MPAPI.matchmaking.guard_queued(sentinel)
check(blocked2 == true, 'guard_queued returns true when searching (caller aborts)')
check(envg2.overlay_shown_count() == 1, 'guard_queued shows the overlay when searching')
check(envg2.MPAPI._internal.mm.pending_action == sentinel, 'guard_queued stashes the caller-supplied replay closure verbatim')
check(envg2.G.SETTINGS.paused == true, 'guard_queued pauses while the overlay is up')

------------------------
-- Run gate: not searching -> start_run proceeds untouched (zero overhead)
------------------------

print()
print('-- run gate: fixed, not searching --')
local env1 = make_env()
load_guard(guard_src, env1)
env1.set_searching(false)
env1.call_start_run()
check(env1.start_run_calls() == 1, 'fixed: original start_run called when not searching')
check(env1.overlay_shown_count() == 0, 'fixed: guard overlay not shown when not searching')

------------------------
-- Run gate: searching -> start_run blocked, overlay shown instead
------------------------

print()
print('-- run gate: fixed, searching --')
local env2 = make_env()
load_guard(guard_src, env2)
env2.set_searching(true)
env2.call_start_run()
check(env2.start_run_calls() == 0, 'fixed: original start_run NOT called while searching')
check(env2.overlay_shown_count() == 1, 'fixed: guard overlay shown while searching')

------------------------
-- Run gate: "Leave Queue & Continue" -- blocked action stashed as a replay
-- closure, replaying it after leaving proceeds through the (now-open) gate
------------------------

print()
print('-- run gate: leave queue and continue (stash + replay) --')
local env3 = make_env()
load_guard(guard_src, env3)
env3.set_searching(true)
local marker_args = { tag = 'replay-me' }
env3.G.FUNCS.start_run(nil, marker_args)
local mm3 = env3.MPAPI._internal.mm
check(env3.start_run_calls() == 0, 'leave-and-continue: blocked while searching')
check(type(mm3.pending_action) == 'function', 'leave-and-continue: blocked action stashed as a replay closure')

-- Simulate the overlay button: leave queue (is_queued flips false), replay.
env3.set_searching(false)
local action3 = mm3.pending_action
mm3.pending_action = nil
action3()
check(env3.start_run_calls() == 1, 'leave-and-continue: replayed action proceeds after leaving')
check(env3.last_start_run_args() == marker_args, 'leave-and-continue: replay carried the original args')

-- Replay must re-check the gate: if still searching, it re-blocks.
local env3b = make_env()
load_guard(guard_src, env3b)
env3b.set_searching(true)
env3b.call_start_run()
local mm3b = env3b.MPAPI._internal.mm
local action3b = mm3b.pending_action
action3b() -- still searching
check(env3b.start_run_calls() == 0, 'leave-and-continue: replay while STILL searching re-blocks (no run starts)')

------------------------
-- Run gate RED control: pre-fix source has no gate -- run starts while searching
------------------------

print()
print('-- run gate: pre-fix control (proves the test is meaningful) --')
local env_broken = make_env()
load_guard(broken_guard_src, env_broken)
env_broken.set_searching(true)
env_broken.call_start_run()
check(env_broken.start_run_calls() == 1, 'broken: (control) start_run proceeds even while searching -- reproduces the bug')
check(env_broken.overlay_shown_count() == 0, 'broken: (control) no guard overlay ever shown')

------------------------
-- handle:leave() fires the "left" event exactly once
------------------------

print()
print('-- matchmaking handle fires left on leave() --')
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

print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
