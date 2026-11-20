-- Contract test: a Run save carries the vanilla save table, each
-- registered mod's state, the recorder's card ids and the log position, and leaves as parts
-- of at most PART_BYTES that join back into the saved text. Run from the MPAPI repository
-- root: luajit tests/run_save_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

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
	STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
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
bad, why = RS.decode({ v = 1, save = { STATE = 7, GAME = {} } })
check(bad == nil and why:find('version'), 'a version 1 save is refused')
bad, why = RS.decode({ v = RS.FORMAT_VERSION, save = { STATE = G.STATES.SELECTING_HAND, GAME = {} } })
check(bad == nil and why:find('screen'), 'a save taken while a hand is played is refused')
bad, why = RS.decode({ v = RS.FORMAT_VERSION, save = { GAME = {} } })
check(bad == nil and why:find('screen'), 'a save with no STATE is refused')
local shop_env = { v = RS.FORMAT_VERSION, save = { STATE = G.STATES.SHOP, GAME = {} } }
check(RS.decode(shop_env) == shop_env and RS.screen_of(shop_env) == 'SHOP', 'a shop save decodes, screen SHOP')
check(RS.screen_of(good_env) == 'BLIND_SELECT', 'a Blind Select save has screen BLIND_SELECT')

-- restore: mod state goes back through load, the card id map goes into the resolver.
local loaded
RS.register_state('demo', {
	save = function() return {} end,
	load = function(state) loaded = state end,
})
RS.register_state('noload', { save = function() return {} end })
local live_hand = { {}, {}, {} }
G.hand = { cards = live_hand }
-- The loaded cards carry the sort_ids they were saved with; the counter is below them, as it is
-- after a fresh start, so the next new card would reuse one.
live_hand[1].sort_id, live_hand[2].sort_id, live_hand[3].sort_id = 12, 274, 40
G.jokers = { cards = { { sort_id = 90 } } }
G.I = { CARDAREA = { G.hand, G.jokers, { cards = {} } } }
G.sort_id = 66
local resolver = { by_id = {}, assigned = {} }
local restored, err = RS.restore(good_env, resolver)
check(restored, 'restore succeeds: ' .. tostring(err))
check(loaded and loaded.lives == 2, 'the mod got its state back')
check(resolver.by_id[5] == live_hand[1] and resolver.by_id[7] == live_hand[3] and resolver.by_id[0] == nil, 'ids map to cards by place')
check(resolver.assigned[live_hand[1]] and resolver.assigned[live_hand[3]] and not resolver.assigned[live_hand[2]], 'mapped cards are marked taken')
check(G.sort_id >= 274, 'the sort_id counter is raised to the highest loaded card id: ' .. tostring(G.sort_id))
G.sort_id = 500
RS.restore(good_env, { by_id = {}, assigned = {} })
check(G.sort_id == 500, 'the sort_id counter is never lowered')
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

print(string.format('run_save_test: %d checks passed', checks))
