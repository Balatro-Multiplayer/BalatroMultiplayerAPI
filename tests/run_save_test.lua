-- Contract test for api/replay/run_save.lua.
local T = dofile('tests/support.lua')
local check = T.check

-- A Run save is taken at Blind Select, carries the vanilla save table, each registered mod's
-- state, the recorder's card ids and the log position, and leaves as parts of at most
-- PART_BYTES that join back into the saved text.
T.part(function()
	local infos = {}
	local sent = {}
	local lobby = {
		_game = { started = { run_id = 'RUN1' } },
		action = function(_, action_type)
			return {
				send = function(_, _, params)
					sent[#sent + 1] = { type = action_type, params = params }
					return true
				end,
			}
		end,
	}
	local cards = { {}, {}, {} }
	local position, position_hash = 12, string.rep('ab', 32)
	love = { filesystem = {} }
	MPAPI = {
		_internal = {},
		ActionTypes = { mpapi_run_save_part = 'PART_TYPE' },
		replay = {
			_card_ids = { [cards[1]] = 5, [cards[3]] = 7 },
			_next_card_id = 7,
			log_position = function()
				return position, position_hash
			end,
		},
		get_current_lobby = function()
			return lobby
		end,
		get_replay_player_id = function() return 'P1' end,
		has_server_referee = function()
			return true
		end,
		sendDebugMessage = function(msg)
			infos[#infos + 1] = msg
		end,
		sendWarnMessage = function() end,
	}
	local save_runs = 0
	local nothing_saved_flag
	G = {
		F_NO_SAVING = true,
		ARGS = {},
		FILE_HANDLER = { run = false, update_queued = false },
		hand = { cards = cards },
		jokers = { cards = {} },
	}
	function save_run()
		save_runs = save_runs + 1
		nothing_saved_flag = G.F_NO_SAVING
		if G.F_NO_SAVING then return end
		G.ARGS.save_run = { STATE = 7, cardAreas = { hand = { cards = { 'c1', 'c2', 'c3' } }, jokers = { cards = {} } } }
		G.FILE_HANDLER.run = true
		G.FILE_HANDLER.update_queued = true
	end

	local started_with
	Game = {
		start_run = function(_, args)
			started_with[#started_with + 1] = args
		end,
	}
	started_with = {}
	dofile('api/replay/run_save.lua')
	local RS = MPAPI.run_save

	-- A stand-in codec: text in, text out, so sizes are easy to predict.
	RS.codec = {
		pack = function(value)
			return 'P' .. tostring(value.save.STATE)
		end,
		compress = function(text)
			return text
		end,
		to_text = function(binary)
			return binary
		end,
	}

	-- split: parts of at most size, in order, that join into the original.
	local parts = RS.split(string.rep('a', 25), 10)
	check(#parts == 3 and #parts[1] == 10 and #parts[3] == 5, 'split sizes')
	check(table.concat(parts) == string.rep('a', 25), 'split joins back')
	check(#RS.split('', 10) == 1, 'an empty text is one empty part')

	-- card_ids: the recorder's id for each card of each saved area, by position; 0 for an unseen card.
	local ids = RS.card_ids({ hand = { cards = { 'c1', 'c2', 'c3' } }, jokers = { cards = {} } })
	check(ids.hand[1] == 5 and ids.hand[2] == 0 and ids.hand[3] == 7, 'card ids by position')
	check(ids.jokers == nil, 'an area with no known card is left out')

	-- mod state: only registered hooks, a nil result leaves the mod out.
	RS.register_state('demo', {
		save = function()
			return { lives = 3 }
		end,
	})
	RS.register_state('idle', {
		save = function()
			return nil
		end,
	})
	RS.register_state('broken', {
		save = function()
			error('boom')
		end,
	})
	local mods = RS.collect_state()
	check(mods.demo.lives == 3 and mods.idle == nil and mods.broken == nil, 'mod state collected, failures skipped')

	-- take: sends the parts, restores the saving flags, logs both sizes.
	local ok = RS.take()
	check(ok, 'take succeeds')
	check(nothing_saved_flag == false, 'saving was switched on for the save')
	check(G.F_NO_SAVING == true, 'and back off after')
	check(G.FILE_HANDLER.run == false and G.FILE_HANDLER.update_queued == false, 'no save file write is left queued')
	check(#sent >= 1, 'parts were sent')
	local first = sent[1].params
	check(sent[1].type == 'PART_TYPE', 'to the part action')
	check(first.run == 'RUN1' and first.pos == 12 and first.hash == position_hash, 'run, position and hash')
	check(first.index == 0 and first.count == #sent, 'part numbering')
	local joined = {}
	for i, s in ipairs(sent) do
		check(s.params.id == first.id and s.params.index == i - 1, 'one id, ascending index')
		check(#s.params.data <= RS.PART_BYTES, 'part within the limit')
		joined[#joined + 1] = s.params.data
	end
	check(#infos > 0 and infos[#infos]:find('raw') and infos[#infos]:find('compressed'), 'sizes are logged')

	-- A save bigger than one part is split, and the parts join into the packed text.
	local big = 'P' .. string.rep('y', RS.PART_BYTES * 2 + 100)
	RS.codec.pack = function()
		return big
	end
	sent = {}
	check(RS.take() and #sent == 3 and sent[1].params.count == 3, 'three parts')
	local text = {}
	for _, s in ipairs(sent) do
		text[#text + 1] = s.params.data
	end
	check(table.concat(text) == big, 'the parts join back into the whole')

	-- A save over the part budget is dropped, not sent in part.
	sent = {}
	RS.codec.pack = function()
		return string.rep('q', RS.PART_BYTES * RS.MAX_PARTS + 1)
	end
	check(not RS.take(), 'a too large save is not taken')
	check(#sent == 0, 'and nothing is sent')

	-- A lobby that is catching up after a rejoin takes no save, whatever the recorder holds.
	RS.codec.pack = function()
		return 'small'
	end
	sent = {}
	local runs_before = save_runs
	lobby._catching_up = true
	check(not RS.take() and #sent == 0 and save_runs == runs_before, 'no save while the lobby is catching up')
	lobby._catching_up = false
	check(RS.take() and #sent >= 1, 'a save is taken again once the catch-up is over')

	-- No log position (a resumed run): no save.
	RS.codec.pack = function()
		return 'small'
	end
	position = nil
	sent = {}
	check(not RS.take() and #sent == 0, 'no save without a log position')

	-- decode: the reverse of take's codec. A good text gives the envelope; a bad one gives nil and why.
	local good_env = {
		v = RS.FORMAT_VERSION,
		save = { STATE = 7, GAME = {}, cardAreas = {} },
		mods = { demo = { lives = 2 } },
		card_ids = { hand = { 5, 0, 7 } },
		next_card_id = 7,
	}
	RS.codec = {
		pack = function(v) return v end,
		compress = function(t) return t end,
		to_text = function(t) return t end,
		unpack = function(t) return t end,
		decompress = function(t) return t end,
		from_text = function(t) return t end,
	}
	local env = RS.decode(good_env)
	check(env == good_env, 'a good text decodes to its envelope')
	local bad, why = RS.decode(setmetatable({}, { __index = function() error('boom') end }))
	check(bad == nil and why:find('boom'), 'a codec failure is a reason, not an error')
	bad, why = RS.decode({ v = RS.FORMAT_VERSION + 1, save = { GAME = {} } })
	check(bad == nil and why:find('version'), 'a newer format is refused')
	bad, why = RS.decode({ v = RS.FORMAT_VERSION })
	check(bad == nil and why:find('save'), 'an envelope with no save table is refused')
	bad, why = RS.decode({ v = RS.FORMAT_VERSION, save = { STATE = 7 } })
	check(bad == nil and why:find('GAME'), 'a save with no GAME is refused')

	-- restore: mod state goes back through load, the card id map goes into the resolver.
	local loaded
	RS.register_state('demo', {
		save = function() return {} end,
		load = function(state) loaded = state end,
	})
	RS.register_state('noload', { save = function() return {} end })
	local live_hand = { {}, {}, {} }
	G.hand = { cards = live_hand }
	local resolver = { by_id = {}, assigned = {} }
	local restored, err = RS.restore(good_env, resolver)
	check(restored, 'restore succeeds: ' .. tostring(err))
	check(loaded and loaded.lives == 2, 'the mod got its state back')
	check(resolver.by_id[5] == live_hand[1] and resolver.by_id[7] == live_hand[3] and resolver.by_id[0] == nil, 'ids map to cards by place')
	check(resolver.assigned[live_hand[1]] and resolver.assigned[live_hand[3]] and not resolver.assigned[live_hand[2]], 'mapped cards are marked taken')
	RS.register_state('failing', { save = function() return {} end, load = function() error('nope') end })
	good_env.mods.failing = {}
	restored, err = RS.restore(good_env, { by_id = {}, assigned = {} })
	check(not restored and tostring(err):find('failing'), 'a failing load is a failed restore naming the mod')

	-- stage_load: the next Game:start_run gets the save as its savetext, once.
	started_with = {}
	check(type(RS.stage_load) == 'function', 'stage_load exists')
	RS.stage_load(good_env)
	Game:start_run({ seed = 'X' })
	check(started_with[1].savetext == good_env.save and started_with[1].seed == 'X', 'the staged save is the savetext')
	Game:start_run({ seed = 'Y' })
	check(started_with[2].savetext == nil, 'and only for one start')
	RS.stage_load(good_env)
	RS.unstage_load()
	Game:start_run({})
	check(started_with[3].savetext == nil, 'an unstaged save is not used')

	-- is_staged: a query for "a Run save waits for the next start".
	check(RS.is_staged() == false, 'nothing is staged at first')
	RS.stage_load(good_env)
	check(RS.is_staged() == true, 'a staged save is reported')
	Game:start_run({})
	check(RS.is_staged() == false, 'the start used it')
	RS.stage_load(good_env)
	RS.unstage_load()
	check(RS.is_staged() == false, 'an unstaged save is not reported')

	-- take_local: the same save goes to this player's local file; nothing is sent.
	position = 12
	RS.codec.pack = function()
		return 'small'
	end
	local files = {}
	local write_result = true
	local function player_of(file) return file:match('^mpapi_local_run_save_(.-)%.txt$') end
	love = {
		filesystem = {
			write = function(file, text)
				if write_result == 'error' then error('disk full') end
				if write_result then files[player_of(file)] = text end
				return write_result, 'no space'
			end,
			read = function(file) return files[player_of(file)] end,
			remove = function(file) files[player_of(file)] = nil end,
		},
	}
	MPAPI.get_replay_player_id = function() return 'P1' end
	sent = {}
	check(RS.take_local() and #sent == 0, 'a local save sends nothing')
	check(files.P1:match('^RUN1 P1 12 ' .. position_hash .. '\n.+'), 'the file holds the run, player, position, hash and the save text')
	check(G.F_NO_SAVING == true and G.FILE_HANDLER.run == false, 'saving flags and the file queue are left as they were')
	local parsed = RS.parse_local(files.P1)
	check(parsed.run == 'RUN1' and parsed.player == 'P1' and parsed.pos == 12 and parsed.hash == position_hash and #parsed.data > 0, 'the file text reads back')
	check(RS.read_local().pos == 12, 'read_local gives the parsed save')
	check(RS.parse_local('garbage') == nil and RS.parse_local(nil) == nil and RS.parse_local('RUN1 P1 x y\ndata') == nil, 'unreadable file text gives nil')

	-- Two game windows on one machine: each player has its own file, and one never reads the other's.
	MPAPI.get_replay_player_id = function() return 'P2' end
	check(RS.read_local() == nil, 'another player has no local save yet')
	position = 20
	check(RS.take_local() and files.P2:match('^RUN1 P2 20 ') and files.P1:match('^RUN1 P1 12 '), 'each player has a file of its own')
	files.P2 = files.P1
	check(RS.read_local() == nil, 'a file written for another player is not read')
	MPAPI.get_replay_player_id = function() return nil end
	check(not RS.take_local(), 'no local save while the player is unknown')
	MPAPI.get_replay_player_id = function() return 'P1' end
	MPAPI.get_replay_player_id = function() return 'a/b c' end
	check(RS.take_local() and files.a_b_c ~= nil, 'the player id is safe in a file name')
	files.a_b_c = nil
	MPAPI.get_replay_player_id = function() return 'P1' end

	-- clear_local removes only this player's file.
	RS.clear_local()
	check(files.P1 == nil and files.P2 ~= nil, 'clear_local removes only the own player file')

	-- take() sends the save and keeps the same text locally, built once.
	files = {}
	position = 15
	sent = {}
	local packs = 0
	RS.codec.pack = function()
		packs = packs + 1
		return 'small'
	end
	check(RS.take() and #sent >= 1 and packs == 1, 'take builds the save once')
	check(files.P1 and files.P1:match('^RUN1 P1 15 '), 'and keeps it as the local copy')

	files = {}
	lobby._catching_up = true
	check(not RS.take_local() and next(files) == nil, 'no local save while the lobby is catching up')
	lobby._catching_up = false
	position = nil
	check(not RS.take_local() and next(files) == nil, 'no local save without a log position')
	position = 12
	local warned = {}
	MPAPI.sendWarnMessage = function(message) warned[#warned + 1] = message end
	write_result = false
	check(not RS.take_local() and warned[#warned]:find('no space'), 'a failed write is reported with its reason')
	write_result = 'error'
	check(not RS.take_local(), 'a write that raises is reported as not saved')
end)

-- The Run save of a Blind Select waits behind the events ahead of it, as vanilla's own save of
-- that screen does. A deck that adds its starting cards in a delayed event (the Ghost Deck's
-- Hex) has them only after that delay, and a Run save taken before it lacks them.
T.part(function()
	local added = {}
	Event = function(opts)
		return opts
	end
	G = {
		STATE_COMPLETE = false,
		E_MANAGER = {
			add_event = function(_, event)
				added[#added + 1] = event
			end,
		},
	}
	Game = {
		update_blind_select = function()
			G.STATE_COMPLETE = true
		end,
	}
	MPAPI = {
		_internal = {},
		replay = {},
		sendWarnMessage = function() end,
		get_current_lobby = function() return { mod_id = 'mod' } end,
	}
	dofile('api/replay/run_save.lua')

	Game:update_blind_select(0.1)
	check(#added == 1, 'the screen build queues one Run save event, got ' .. #added)
	check(added[1].blockable ~= false, 'the Run save event can be blocked by the events ahead of it')
	check(added[1].trigger == 'immediate', 'and it runs as soon as they are done')
	Game:update_blind_select(0.1)
	check(#added == 1, 'a screen that is already built queues none')

	-- The queued event goes through the save-point decision: with a waiting mod nothing is taken, and
	-- when the mod says now the save is taken once.
	local RS = MPAPI.run_save
	local taken = 0
	RS.take = function()
		taken = taken + 1
		return true
	end
	local busy = true
	RS.register_save_wait('mod', function() return busy end)
	added[1].func()
	check(taken == 0, 'a waiting mod: the queued event takes nothing')
	busy = false
	check(RS.save_now() and taken == 1, 'the mod says now: the save is taken')
end)

-- A mod can say "not now" at a save point; the save is taken when no mod says "not now" any
-- more, and only if no newer save-point screen has started. A mod that registers nothing gets
-- the save at once.
T.part(function()
	G = { STATE = 'BLIND_SELECT', STATE_COMPLETE = true }
	local current_mod = 'mod'
	MPAPI = {
		_internal = {},
		replay = {},
		sendWarnMessage = function() end,
		get_current_lobby = function() return { mod_id = current_mod } end,
	}
	dofile('api/replay/run_save.lua')
	local RS = MPAPI.run_save

	local taken = 0
	RS.take = function()
		taken = taken + 1
		return true
	end

	-- No mod registered: the save is taken at once, as before.
	check(RS.at_save_point(RS.start_save_point()) and taken == 1, 'no waiting mod: taken at once')
	check(not RS.save_now() and taken == 1, 'and save_now has nothing to take')

	-- A mod says not now: nothing is taken until it says now.
	local busy = true
	RS.register_save_wait('mod', function()
		return busy
	end)
	check(not RS.at_save_point(RS.start_save_point()) and taken == 1, 'not now: not taken')
	busy = false
	check(RS.save_now() and taken == 2, 'now: taken')
	check(not RS.save_now() and taken == 2, 'taken only once')

	-- Another mod's hook that says wait does not hold back this lobby's save (a Speedrun lobby is not
	-- held by leftover PvP state), and is not asked.
	local other_asked = false
	RS.register_save_wait('other', function()
		other_asked = true
		return true
	end)
	busy = false
	check(RS.at_save_point(RS.start_save_point()) and taken == 3, 'another mod waiting: this lobby is not held')
	check(not other_asked, 'and its hook is not asked')
	current_mod = 'other'
	check(not RS.at_save_point(RS.start_save_point()) and other_asked and taken == 3, 'the lobby of the waiting mod is held')
	RS.register_save_wait('other', function()
		return false
	end)
	current_mod = 'mod'

	-- The game leaves the screen and comes back to the same state before the mod says now: the old
	-- wait takes nothing, because a newer save-point screen has started.
	busy = true
	RS.at_save_point(RS.start_save_point())
	RS.start_save_point()
	busy = false
	check(G.STATE == 'BLIND_SELECT' and not RS.save_now() and taken == 3, 'came back to the same state: the old wait takes no save')

	-- A queued event of a replaced screen takes nothing and puts nothing off.
	local old_point = RS.start_save_point()
	RS.start_save_point()
	check(not RS.at_save_point(old_point) and taken == 3, 'an event of a replaced screen takes nothing')
	check(not RS.save_now() and taken == 3, 'and leaves nothing waiting')

	-- The game moves on from the save point before the mod says now (a blind chosen, a hand played): the
	-- save is not taken at the later state, nor while the save point's screen is not built.
	busy = true
	RS.at_save_point(RS.start_save_point())
	busy = false
	G.STATE = 'HAND_PLAYED'
	check(not RS.save_now() and taken == 3, 'the state changed since the save point: no save')
	G.STATE = 'BLIND_SELECT'
	G.STATE_COMPLETE = false
	check(not RS.save_now() and taken == 3, 'the screen is not built: no save')
	G.STATE_COMPLETE = true
	check(RS.save_now() and taken == 4, 'back at the built save point: taken')
	taken = 3

	-- A newer save point replaces the waiting one.
	busy = true
	RS.at_save_point(RS.start_save_point())
	busy = false
	check(RS.at_save_point(RS.start_save_point()) and taken == 4, 'newer save point with no wait is taken at once')
	check(not RS.save_now() and taken == 4, 'and the old wait is gone')

	-- The lobby is left or the run ends: the wait is cleared.
	busy = true
	RS.at_save_point(RS.start_save_point())
	busy = false
	RS.clear_wait()
	check(not RS.save_now() and taken == 4, 'a cleared wait takes no save')

	-- A wait hook that errors does not stop the save, even when its mod id is not text.
	RS.register_save_wait(7, function()
		error('broken')
	end)
	current_mod = 7
	check(RS.at_save_point(RS.start_save_point()) and taken == 5, 'a broken hook is skipped')
end)

T.done('run_save_test')
