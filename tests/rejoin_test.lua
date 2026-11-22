-- Contract test for api/playback/rejoin.lua.
local T = dofile('tests/support.lua')
local check = T.check

-- A rejoin gives its join the Run save it then loads and replays from, and ends when that save
-- will not load.
T.part(function()
	local order = {}
	local restored_with, restore_result
	local fake_envelope = { v = 1, save = { GAME = {} }, mods = {}, card_ids = {} }
	MPAPI = {
		playback = {},
		replay = {
			new_resolver_state = function() return { by_id = {}, assigned = {} } end,
			resume_run = function(events, by_id, log_text)
				order[#order + 1] = 'resume_run'
				MPAPI.resumed_with = { events = events, by_id = by_id, log_text = log_text }
			end,
		},
		run_save = {
			SKIP = { LOAD_FAILED = 'load_failed' },
			read_local = function() return nil end,
			clear_local = function() order[#order + 1] = 'clear_local' end,
			stage_load = function() end,
			unstage_load = function() end,
			restore = function(envelope, resolver)
				restored_with = { envelope = envelope, resolver = resolver }
				if restore_result == 'throw' then error('boom') end
				return restore_result, restore_result and nil or 'bad state'
			end,
		},
		sendWarnMessage = function() end,
	}
	dofile('api/playback/rejoin.lua')
	local P = MPAPI.playback

	local made_driver = false
	P.new_driver = function()
		made_driver = true
		return {}
	end

	local session = { my_id = 'me', timeline = {}, bootstrap = { schema_version = 1 } }
	local function options(extra)
		local o = { mod_id = 'm', start_run = function(_, on_ready) on_ready() end }
		for k, v in pairs(extra or {}) do o[k] = v end
		return o
	end

	P.new_driver = function()
		made_driver = true
		return { _cursor = 1, _card_resolvers = {}, finish = function() end, stop = function() end, fast_forward_to = function(_, _, o) o.on_done() end }
	end

	-- A run started from a save restores it into the driver's cards and replays after it.
	restore_result = true
	local replay_ready = false
	P.restart_session_and_seek(session, 3, function() replay_ready = true end, options({ run_save = { envelope = fake_envelope, pos = 6 } }))
	check(made_driver and replay_ready, 'the save is loaded and the log after it is replayed')
	check(restored_with.envelope == fake_envelope, 'the restore gets the save')

	-- A save that does not restore: the caller is told, nothing goes live.
	for _, result in ipairs({ false, 'throw' }) do
		restore_result = result
		local failed, went_live = nil, false
		P.restart_session_and_seek(session, 3, function() went_live = true end, options({
			run_save = { envelope = fake_envelope, pos = 6 },
			on_load_failed = function(code) failed = code end,
		}))
		check(failed == 'load_failed' and not went_live, 'a failed restore reports and does not go live (' .. tostring(result) .. ')')
	end
	restore_result = true

	-- resume_recording: the recorder reopens with the loaded cards, then the lobby stops catching up.
	local lobby = { set_catching_up = function(_, value) order[#order + 1] = 'catching_up_' .. tostring(value) end }
	local events = { { t = 1 } }
	local cards = { by_id = { [5] = 'card' } }
	order = {}
	P.resume_recording(lobby, events, cards, 'LOG')
	check(MPAPI.resumed_with.events == events and MPAPI.resumed_with.by_id == cards.by_id and MPAPI.resumed_with.log_text == 'LOG', 'the recorder gets the log and the loaded cards')
	check(table.concat(order, ',') == 'clear_local,resume_run,catching_up_false', 'the old local save goes, the recorder reopens, then catching up ends')
	P.resume_recording(lobby, events, nil, nil)
	check(MPAPI.resumed_with.by_id == nil, 'with no cards the recorder gets none')

	-- run_rejoin, wired end to end with stubs for the lobby, the run start and the game's event queue.
	dofile('lib/join_keys.lua')
	local queued = {}
	G = { STATE = 1, STATES = { SPLASH = 0 }, E_MANAGER = { add_event = function(_, event) queued[#queued + 1] = event end } }
	Event = function(spec) return spec end
	local notices = {}
	localize = function(key) return key end
	MPAPI.show_notice = function(title, body) notices[#notices + 1] = { title = title, body = body } end
	MPAPI.OPCODE = { MATCH_MANIFEST = 'manifest', LOBBY_INFO = 'lobby_info', RUN_INFO = 'run_info' }
	MPAPI.get_replay_player_id = function() return 'me' end
	MPAPI.LobbyEvent = { DISCONNECTED = 'disconnected' }
	P.new_driver = function()
		made_driver = true
		return { _cursor = 1, _card_resolvers = {}, finish = function() end, stop = function() end, play = function() end, fast_forward_to = function(_, _, o) o.on_done() end }
	end
	MPAPI.replay.is_schema_compatible = function() return true end
	MPAPI.replay.SCHEMA_VERSION = 1
	MPAPI.shallow_copy = function(t)
		local copy = {}
		for k, v in pairs(t) do copy[k] = v end
		return copy
	end
	MPAPI.get_current_lobby = function() end
	MPAPI.sendDebugMessage = function() end
	P._queues_empty = function() return true end
	P.timeline_ante_starts = function() return {} end
	P.reset_gave_up_waits = function() end
	P.gave_up_waits = function() return 0 end

	local decoded = 0
	fake_envelope.tag = 'the save'
	for _, code in ipairs({ 'NOT_SUPPORTED', 'NO_SAVE', 'HASH_MISMATCH', 'BEYOND_LOG', 'EARLIER_RUN', 'UNREADABLE', 'START_TIMEOUT' }) do
		MPAPI.run_save.SKIP[code] = code:lower()
	end
	MPAPI.run_save.decode = function()
		decoded = decoded + 1
		return fake_envelope
	end

	local log = {
		{ t = 1, opcode = 'manifest', args = { schema_version = 1 } },
		{ t = 2, opcode = 'lobby_info', args = { gamemode = 'g', ruleset = 'r' } },
		{ t = 3, opcode = 'run_info', args = { seed = 's', stake = 1 } },
		{ t = 4, opcode = 'other', args = {} },
	}

	-- Runs a rejoin and returns what the join was given and what the lobby saw.
	local function rejoin(run_save, mod_id)
		mod_id = mod_id or 'm'
		order, queued, made_driver, decoded, restored_with = {}, {}, false, 0, nil
		local seen = { join_keys = {} }
		MPAPI.add_join_keys('m', function(save_to_load)
			seen.asked_with = save_to_load or 'nil'
			return { pvp_run = save_to_load and save_to_load.tag or 'no save' }
		end)
		local lobby = {
			_destroyed = false,
			set_catching_up = function(_, value) order[#order + 1] = 'catching_up_' .. tostring(value) end,
			set_gamemode_instance = function() end,
			on = function() end,
			leave = function() seen.left = true end,
		}
		local first_snapshot
		MPAPI.networking = { nakama_lobby = { step_out = function() seen.stepped_out = true; return 'x' end } }
		MPAPI._internal = {
			create_detached_lobby = function(_, on_ready, save_to_load)
				seen.join_save = save_to_load
				seen.join_keys = MPAPI.join_keys.with_mod_keys('m', {}, save_to_load)
				first_snapshot = on_ready
				return lobby
			end,
			lobby = { attach_detached = function() order[#order + 1] = 'attach' end, cleanup = function(l) seen.cleaned = l end },
		}
		local hooks = {
			playback_mod_id = 'm',
			supports_run_save = true,
			read_lobby_info = function() end,
			read_run_info = function() end,
			start_run = function(_, on_ready) on_ready() end,
			attach = function() end,
			aborted = function() seen.aborted = true end,
		}
		P.run_rejoin({ runId = 'r', events = log, logText = 'LOG', runSave = run_save }, { matchId = 'x', modId = mod_id }, hooks)
		first_snapshot()
		for _, event in ipairs(queued) do
			if event.no_delete then event.func() end
		end
		return seen
	end

	local good_save = { id = 's', pos = 3, hash = 'h', data = 'TEXT' }

	-- A good save: the join keys describe it, it is loaded, and the log after it is replayed.
	local seen = rejoin(good_save)
	check(seen.join_save == fake_envelope and seen.join_keys.pvp_run == 'the save', 'the join keys describe the save about to be loaded')
	check(restored_with.envelope == seen.join_save, 'the save loaded is the save the join was given')
	check(decoded == 1, 'the save is chosen once')
	check(made_driver, 'the log after the save is replayed')

	-- No good save: the join keys get nil and the whole log is played.
	seen = rejoin(nil)
	check(seen.join_save == nil and seen.asked_with == 'nil' and made_driver, 'with no good save the join keys get nil and the whole log is played')

	-- The save does not load. The join keys describe that save, so the rejoin ends, with a notice and
	-- no leave: the seat follows the server's own path.
	restore_result = false
	seen = rejoin(good_save)
	check(seen.aborted and not seen.left, 'a failed load ends the rejoin without a leave')
	check(#notices == 1 and notices[1].body == 'k_rejoin_load_failed_body', 'and says why')
	check(table.concat(order, ',') == 'catching_up_true', 'and the run does not go live')
	check(seen.stepped_out, 'the socket steps out of the match so the server marks the seat away')
	check(seen.cleaned ~= nil, 'the detached lobby is cleaned up so the player can join or queue again')

	-- A mod that registered no join keys keeps its earlier behaviour: the whole log is played.
	notices = {}
	seen = rejoin(good_save, 'plain')
	check(not seen.aborted and not seen.left and #notices == 0 and made_driver, 'no join keys: a failed load plays the whole log')
	check(not seen.stepped_out and seen.cleaned == nil, 'and the seat stays attached')
	restore_result = true
end)

-- A crash rejoin starts from the player's Run save when the mod can load one and the save
-- checks out, and otherwise plays the whole log.
T.part(function()
	local staged, restored_with, restore_result
	local fake_envelope = { v = 1, save = { GAME = {} }, mods = {}, card_ids = {} }
	local decode_result = fake_envelope
	local local_save = nil
	local decoded_texts = {}
	MPAPI = {
		playback = {},
		OPCODE = { RUN_INFO = 'run_info' },
		replay = {
			hash_events = function(_, count) return 'H' .. count end,
			new_resolver_state = function() return { by_id = {}, assigned = {} } end,
		},
		run_save = {
			SKIP = {
				NOT_SUPPORTED = 'not_supported', NO_SAVE = 'no_save', HASH_MISMATCH = 'hash_mismatch', BEYOND_LOG = 'beyond_log',
				EARLIER_RUN = 'earlier_run', UNREADABLE = 'unreadable', LOAD_FAILED = 'load_failed', START_TIMEOUT = 'start_timeout',
			},
			read_local = function() return local_save end,
			decode = function(text)
				decoded_texts[#decoded_texts + 1] = text
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
		local a = { runId = 'RUN1', events = events, runSave = { id = 's', pos = 6, hash = 'h', data = 'TEXT' } }
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

	-- The local save (MPAPI.run_save.take_local) competes with the server's: the newer one wins.
	local function mine(extra)
		local save = { run = 'RUN1', player = 'P1', pos = 8, hash = 'H8', data = 'LOCAL' }
		for k, v in pairs(extra or {}) do save[k] = v end
		return save
	end
	local_save = mine()
	decoded_texts = {}
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pick == fake_envelope and pos == 8 and decoded_texts[1] == 'LOCAL', 'a newer local save beats the server copy')
	local_save = mine({ pos = 4, hash = 'H4' })
	decoded_texts = {}
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pos == 6 and decoded_texts[1] == 'TEXT', 'an older local save loses to the server copy')
	local_save = mine({ run = 'OTHER' })
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pos == 6, 'a local save of another run is never used')
	local_save = mine({ pos = 12, hash = 'H12' })
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pos == 6, 'a local save past the downloaded log falls back to the server copy')
	local_save = mine()
	pick, pos = P.pick_rejoin_start(active({ runSave = false }), hooks)
	check(pos == 8, 'a local save alone starts the rejoin')
	pick, pos = P.pick_rejoin_start(active({ runSave = false, runSaveSkipped = 'hash_mismatch' }), hooks)
	check(pos == 8, 'a local save is used even when the server held its own back')
	local_save = mine()
	local_save.pos = nil
	none, why = P.pick_rejoin_start(active({ runSave = false }), hooks)
	check(none == nil and why == 'no_save', 'a local save with no position is left out')
	-- Same run, fits the log, but taken on events the server never received: its hash is not the
	-- downloaded log's, so it is never loaded.
	local_save = mine({ hash = 'H_OTHER_TIMELINE' })
	decoded_texts = {}
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pos == 6 and decoded_texts[1] == 'TEXT', 'a local save of another timeline falls back to the server copy')
	none, why = P.pick_rejoin_start(active({ runSave = false }), hooks)
	check(none == nil and why == 'hash_mismatch', 'and with no server copy the whole log is played')
	-- The server copy's hash is the server's to check: one this client cannot reproduce does not refuse it.
	local_save = nil
	pick, pos = P.pick_rejoin_start(active({ runSave = { id = 's', pos = 9, hash = 'unrelated', data = 'TEXT' } }), hooks)
	check(pos == 9, 'a server copy is not re-hashed here')
	local_save = mine()
	local calls = 0
	local real_decode = MPAPI.run_save.decode
	MPAPI.run_save.decode = function(text)
		calls = calls + 1
		if text == 'LOCAL' then return nil, 'garbled' end
		return real_decode(text)
	end
	pick, pos = P.pick_rejoin_start(active(), hooks)
	check(pos == 6 and calls == 2, 'an unreadable local save falls back to the server copy')
	MPAPI.run_save.decode = real_decode
	local_save = nil

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
end)

T.done('rejoin_test')
