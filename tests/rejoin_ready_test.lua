-- Contract test: a restart from a Run save puts the save's extras back and seeks only once the
-- run shows the save's screen (Blind Select, or a shop with its cards). A run that never gets
-- there ends in START_TIMEOUT, even though the run start clears the event queue. Run from the
-- MPAPI repository root: luajit tests/rejoin_ready_test.lua (an optional argument names another
-- rejoin.lua to load).
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local clock = 0
love = {
	timer = {
		getTime = function()
			return clock
		end,
	},
}

-- An event queue with vanilla's clear_queue: every event without no_delete goes.
local queue = {}
function Event(config)
	config.created = clock
	return config
end
G = {
	STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
	STATE = 0,
	E_MANAGER = {
		add_event = function(_, ev)
			queue[#queue + 1] = ev
		end,
		clear_queue = function()
			local kept = {}
			for _, ev in ipairs(queue) do
				if ev.no_delete then
					kept[#kept + 1] = ev
				end
			end
			queue = kept
		end,
	},
}
local function tick(seconds)
	clock = clock + seconds
	local left = {}
	for _, ev in ipairs(queue) do
		local due = ev.trigger ~= 'after' or clock - ev.created >= ev.delay
		if not (due and ev.func()) then
			left[#left + 1] = ev
		end
	end
	queue = left
end

local shop_built = false
local screen = 'SHOP'
local restores = 0
local envelope = { v = 2, save = { STATE = 5, GAME = {} } }
MPAPI = {
	playback = {
		shop_is_built = function()
			return shop_built
		end,
	},
	replay = {
		new_resolver_state = function()
			return { by_id = {}, assigned = {} }
		end,
	},
	run_save = {
		SKIP = { LOAD_FAILED = 'load_failed', START_TIMEOUT = 'start_timeout' },
		screen_of = function()
			return screen
		end,
		stage_load = function() end,
		unstage_load = function() end,
		restore = function()
			restores = restores + 1
			return true
		end,
	},
	sendWarnMessage = function() end,
}
dofile(arg and arg[1] or 'api/playback/rejoin.lua')
local P = MPAPI.playback

local function new_driver_stub()
	local driver = { _cursor = 1, _card_resolvers = {} }
	function driver:finish() end
	function driver:stop() end
	function driver:fast_forward_to(_, o)
		clock = clock + 2
		o.on_done()
	end
	return driver
end
P.new_driver = new_driver_stub

local events = {}
for i = 1, 10 do
	events[i] = { t = i, opcode = 'x' }
end
local function new_session()
	return { my_id = 'me', timeline = events, bootstrap = { schema_version = 1 } }
end
-- The mod's run start, as vanilla runs it: the queue is cleared and the new run exists, on no
-- screen yet.
local function start_run(_, on_ready)
	G.E_MANAGER:clear_queue()
	G.STATE = 0
	on_ready()
end
local failures = {}
local function seek(session, ready)
	P.restart_session_and_seek(session, 3, ready, {
		mod_id = 'm',
		start_run = start_run,
		run_save = { envelope = envelope, pos = 6 },
		on_load_failed = function(code, detail)
			failures[#failures + 1] = { code = code, detail = detail }
		end,
	})
end

-- 1. A shop save: nothing is restored until the shop has its cards.
local ready_driver
local session = new_session()
seek(session, function(d)
	ready_driver = d
end)
check(restores == 0 and ready_driver == nil, 'no restore before the run shows its screen')
G.STATE = G.STATES.SHOP
tick(0.1)
check(restores == 0 and ready_driver == nil, 'no restore in a shop without its cards')
shop_built = true
tick(0.1)
check(restores == 1 and ready_driver ~= nil, 'restored and sought once the shop is built')
tick(40)
check(#failures == 0, 'a run that got there is not timed out')

-- 2. A Blind Select save waits for Blind Select.
screen, shop_built, restores, ready_driver = 'BLIND_SELECT', false, 0, nil
seek(new_session(), function(d)
	ready_driver = d
end)
G.STATE = G.STATES.SHOP
shop_built = true
tick(0.1)
check(restores == 0, 'a shop is not the Blind Select a save was taken at')
G.STATE = G.STATES.BLIND_SELECT
tick(0.1)
check(restores == 1 and ready_driver ~= nil, 'restored once Blind Select shows')

-- 3. A run that never reaches its screen ends in START_TIMEOUT, though the start cleared the queue.
screen, shop_built, restores, ready_driver = 'SHOP', false, 0, nil
seek(new_session(), function(d)
	ready_driver = d
end)
tick(P.RUN_SAVE_START_SECONDS + 1)
check(#failures == 1 and failures[1].code == 'start_timeout', 'a stuck run start times out')
check(tostring(failures[1].detail):find('saved screen') ~= nil, 'and says it did not reach the saved screen')
G.STATE, shop_built = G.STATES.SHOP, true
tick(0.1)
check(restores == 0 and ready_driver == nil, 'a timed out attempt does not restore later')

-- 4. A newer restart ends the older attempt: its watch does nothing.
failures, restores = {}, 0
G.STATE, shop_built = 0, false
local newer = new_session()
seek(newer, function() end)
tick(P.RUN_SAVE_START_SECONDS - 5)
seek(newer, function() end)
G.STATE, shop_built = G.STATES.SHOP, true
tick(0.1)
check(restores == 1, 'the newer attempt restores')
tick(10)
check(#failures == 0, 'the older attempt does not time out the newer one')

-- 5. The restart records its timing, and the catch-up line has three parts.
check(newer.timing and newer.timing.ready_at - newer.timing.restarted_at >= 0, 'load to ready is recorded')
check(newer.timing.fast_forward and newer.timing.fast_forward.seconds == 2, 'the fast-forward seconds are recorded')
local text = P.catch_up_timing_text({ restarted_at = 10, ready_at = 12.5, fast_forward = { events = 40, seconds = 5.2, ended_at = 20 } }, 30, 12)
check(text == 'load to ready 2.5 s, fast-forward 40 events in 5.2 s, tail 12 events in 10.0 s', 'timing text: ' .. text)
check(P.catch_up_timing_text({ restarted_at = 10 }, 11, 0) == 'load to ready none, fast-forward none, tail none', 'parts that did not happen read none')

-- 6. A run start that clears the queue and never comes up still times out.
failures = {}
P.restart_session_and_seek(new_session(), 3, function() end, {
	mod_id = 'm',
	start_run = function()
		G.E_MANAGER:clear_queue()
	end,
	run_save = { envelope = envelope, pos = 6 },
	on_load_failed = function(code)
		failures[#failures + 1] = { code = code }
	end,
})
tick(P.RUN_SAVE_START_SECONDS + 1)
check(#failures == 1 and failures[1].code == 'start_timeout', 'the watch outlives the run start clearing the queue')

-- 7. A run left while it waits (the rejoin aborted, the watch stopped) is not restored into the
-- next run the player starts.
failures, restores = {}, 0
screen = 'BLIND_SELECT'
seek(new_session(), function() end)
G.GAME = { name = 'a run the player started' }
G.STATE = G.STATES.BLIND_SELECT
tick(0.1)
check(restores == 0, 'the next run is not restored into')

-- 8. A save whose screen is unknown is refused, not waited for at Blind Select.
failures, restores = {}, 0
screen = nil
local started = false
P.restart_session_and_seek(new_session(), 3, function() end, {
	mod_id = 'm',
	start_run = function()
		started = true
	end,
	run_save = { envelope = envelope, pos = 6 },
	on_load_failed = function(code, detail)
		failures[#failures + 1] = { code = code, detail = detail }
	end,
})
check(#failures == 1 and failures[1].code == 'load_failed', 'a save with no screen is refused')
check(not started and restores == 0, 'the refused save starts no run')
screen = 'BLIND_SELECT'

-- 9. An unknown screen is a programming error.
check(not pcall(P.when_screen_ready, 'SELECTING_HAND', function() end), 'only BLIND_SELECT and SHOP can be waited for')

print(string.format('rejoin_ready_test: %d checks passed', checks))
