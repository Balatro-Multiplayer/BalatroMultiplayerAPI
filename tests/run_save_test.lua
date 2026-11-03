-- Contract test: a Run save is taken at Blind Select, carries the vanilla save table, each
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

-- No log position (a resumed run): no save.
RS.codec.pack = function()
	return 'small'
end
position = nil
sent = {}
check(not RS.take() and #sent == 0, 'no save without a log position')

print(string.format('run_save_test: %d checks passed', checks))
