-- Contract test: a crash rejoin starts from the player's Run save when the mod can load one and
-- the save checks out, and otherwise plays the whole log. Run from the MPAPI repository root:
-- luajit tests/rejoin_run_save_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local staged, restored_with, restore_result
local fake_envelope = { v = 1, save = { GAME = {} }, mods = {}, card_ids = {} }
local decode_result = fake_envelope
MPAPI = {
	playback = {},
	OPCODE = { RUN_INFO = 'run_info' },
	replay = {
		new_resolver_state = function() return { by_id = {}, assigned = {} } end,
	},
	run_save = {
		SKIP = {
			NOT_SUPPORTED = 'not_supported', NO_SAVE = 'no_save', HASH_MISMATCH = 'hash_mismatch', BEYOND_LOG = 'beyond_log',
			EARLIER_RUN = 'earlier_run', UNREADABLE = 'unreadable', LOAD_FAILED = 'load_failed', START_TIMEOUT = 'start_timeout',
		},
		decode = function(text)
			if decode_result then return decode_result end
			return nil, 'unreadable ' .. tostring(text)
		end,
		stage_load = function(e) staged = e end,
		unstage_load = function() staged = nil end,
		restore = function(e, resolver)
			restored_with = { envelope = e, resolver = resolver }
			return restore_result, restore_result and nil or 'bad state'
		end,
	},
	sendWarnMessage = function() end,
}
dofile('api/playback/rejoin.lua')
local P = MPAPI.playback

local events = {}
for i = 1, 10 do events[i] = { t = i, opcode = 'x' } end
local hooks = { supports_run_save = true }
local function active(extra)
	local a = { events = events, runSave = { id = 's', pos = 6, hash = 'h', data = 'TEXT' } }
	for k, v in pairs(extra or {}) do a[k] = v end
	return a
end

-- pick_rejoin_start: the save, its position, or the reason for the full replay.
local pick, pos = P.pick_rejoin_start(active(), hooks)
check(pick == fake_envelope and pos == 6, 'a good save is picked with its position')
local none, why = P.pick_rejoin_start(active(), {})
check(none == nil and why == 'not_supported', 'a mod that cannot load one plays the whole log')
none, why = P.pick_rejoin_start(active({ runSave = false }), hooks)
check(none == nil and why == 'no_save', 'no save, no Run save path')
none, why = P.pick_rejoin_start(active({ runSave = false, runSaveSkipped = 'hash_mismatch' }), hooks)
check(none == nil and why == 'hash_mismatch', 'a save the server held back says why')
none, why = P.pick_rejoin_start(active({ runSave = { id = 's', pos = 11, hash = 'h', data = 'T' } }), hooks)
check(none == nil and why == 'beyond_log', 'a save past the end of the log is refused')
-- A run that started after the save (a restart, the next run of a race) makes the save an
-- earlier run's: it is never loaded.
local later_run = {}
for i = 1, 10 do later_run[i] = { t = i, opcode = i == 8 and 'run_info' or 'x' } end
none, why = P.pick_rejoin_start(active({ events = later_run }), hooks)
check(none == nil and why == 'earlier_run', 'a save from before a later run start is refused')
later_run[8].opcode = 'x'
later_run[3].opcode = 'run_info'
pick, pos = P.pick_rejoin_start(active({ events = later_run }), hooks)
check(pick == fake_envelope and pos == 6, 'a run start before the save does not matter')
decode_result = nil
none, why = P.pick_rejoin_start(active(), hooks)
check(none == nil and why == 'unreadable', 'an unreadable save is refused with its reason')
decode_result = fake_envelope

-- restart_session_and_seek with a Run save.
local function new_driver_stub()
	local driver = { _cursor = 1, _card_resolvers = {}, stopped = false }
	function driver:finish() self.finished = true end
	function driver:stop() self.stopped = true end
	function driver:fast_forward_to(target, o)
		self.ff_target = target
		o.on_done()
	end
	return driver
end
local made
P.new_driver = function()
	made = new_driver_stub()
	return made
end
local session = { my_id = 'me', timeline = events, bootstrap = { schema_version = 1 } }
local function opts_with(extra)
	local o = {
		mod_id = 'm',
		start_run = function(_, on_ready) on_ready() end,
	}
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

local ready_driver
restore_result = true
P.restart_session_and_seek(session, 3, function(d) ready_driver = d end, opts_with({ run_save = { envelope = fake_envelope, pos = 6 } }))
check(staged == fake_envelope or staged == nil, 'the save was staged before the run start')
check(ready_driver == made, 'the seek ends')
check(made._cursor == 7, 'the driver starts after the save position')
check(made.ff_target == 7, 'and the seek goes no lower than that')
check(restored_with.envelope == fake_envelope and restored_with.resolver == made._card_resolvers.me, 'the card map goes into the player resolver')
P.restart_session_and_seek(session, 9, function() end, opts_with({ run_save = { envelope = fake_envelope, pos = 6 } }))
check(made.ff_target == 9, 'a later cutoff wins')

-- A save that fails to restore: the caller is told, the seek does not go on.
restore_result = false
local failed, failed_detail, ready = nil, nil, false
P.restart_session_and_seek(session, 3, function() ready = true end, opts_with({
	run_save = { envelope = fake_envelope, pos = 6 },
	on_load_failed = function(code, detail) failed, failed_detail = code, detail end,
}))
check(not ready and failed == 'load_failed' and failed_detail:find('bad state') and made.stopped, 'a failed restore stops and reports')

-- Without a save nothing changes.
staged = nil
P.restart_session_and_seek(session, 4, function() end, opts_with())
check(staged == nil and made._cursor == 1 and made.ff_target == 4, 'no save: the cursor stays and the target stands')

-- A spectator's seek: the timeline holds only the events after the save, and more arrive live.
restore_result = true
local watched = { my_id = 'them', timeline = { { t = 7, opcode = 'x' }, { t = 8, opcode = 'x' } }, bootstrap = { schema_version = 1 } }
P.restart_session_and_seek(watched, 3, function() end, opts_with({
	live = true,
	run_save = { envelope = fake_envelope, pos = 6, events_follow = true },
}))
check(made._cursor == 1, 'events that follow the save are played from the first one')
check(made.ff_target == 3, 'the seek target is not raised by the save position')
check(not made.finished, 'a live driver is not told its timeline is complete')
P.restart_session_and_seek(session, 3, function() end, opts_with())
check(made.finished, 'a replay or rejoin driver is told its timeline is complete')

print(string.format('rejoin_run_save_test: %d checks passed', checks))
