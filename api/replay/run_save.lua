-- MPAPI.run_save: takes a Run save at each Blind Select screen of a server-refereed match and
-- sends it to the server in parts (the mpapi_run_save_part action; BalatroMultiplayerServer
-- nakama/src/actions/run_save.ts holds the same part format and limits).
--
-- A Run save is one text: the vanilla save table (RNG state and every card area), the state
-- each registered mod adds through register_state, the recorder's card id map, all packed,
-- compressed and base64 encoded. It is cut into parts of at most PART_BYTES characters. Each
-- part also names the save (id), its place (index of count), the log position it was taken at
-- (pos) and the hash of the log up to there (hash). The server joins the parts and swaps the
-- save in only when the last one arrives, so a drop mid-send never replaces a good save.
--
-- A mod adds its own state with MPAPI.run_save.register_state(mod_id, hooks):
--   save()        -- returns a plain table (no functions, no Card objects), or nil when the mod
--                    has nothing to keep right now (it is not the active mod, say)
--   load(state)   -- (optional) puts a saved table back; called by whoever loads a Run save
MPAPI.run_save = MPAPI.run_save or {}
local RS = MPAPI.run_save

-- Both limits are part of the server contract (run_save.ts: MAX_RUN_SAVE_PART_BYTES,
-- MAX_RUN_SAVE_PARTS). The server refuses a message with more than 16 KB of params.
RS.PART_BYTES = 12 * 1024
RS.MAX_PARTS = 16
RS.FORMAT_VERSION = 1

RS._state_hooks = RS._state_hooks or {}
local seq = 0

-- What turns a table into the text that leaves the client. Replaceable so a test can run
-- without the game. compress uses level 9: vanilla's own save file uses 1 and is about 30%
-- bigger.
RS.codec = RS.codec
	or {
		pack = function(value)
			return STR_PACK(value)
		end,
		compress = function(text)
			return love.data.compress('string', 'deflate', text, 9)
		end,
		to_text = function(binary)
			return love.data.encode('string', 'base64', binary)
		end,
	}

function RS.register_state(mod_id, hooks)
	assert(type(mod_id) == 'string' and type(hooks) == 'table' and type(hooks.save) == 'function', 'MPAPI.run_save.register_state: needs a mod id and a table with save()')
	RS._state_hooks[mod_id] = hooks
end

-- { mod_id = state } for every registered mod that has state to keep. A hook that errors is
-- skipped: one broken mod must not stop the save.
function RS.collect_state()
	local mods = {}
	for mod_id, hooks in pairs(RS._state_hooks) do
		local ok, state = pcall(hooks.save)
		if ok and state ~= nil then
			mods[mod_id] = state
		elseif not ok then
			MPAPI.sendWarnMessage('run_save: state hook of ' .. mod_id .. ' failed: ' .. tostring(state))
		end
	end
	return mods
end

-- Cuts text into pieces of at most size characters, in order. Empty text is one empty piece.
function RS.split(text, size)
	local parts = {}
	for i = 1, math.max(#text, 1), size do
		parts[#parts + 1] = text:sub(i, i + size - 1)
	end
	return parts
end

-- The recorder's id for each card of each saved area, by the card's place in the area. 0 marks
-- a card the recorder has not named. Areas with no named card are left out. Saved cards follow
-- the order of the live area's cards, which is how a loader finds them again.
function RS.card_ids(card_areas)
	local ids = MPAPI.replay._card_ids
	local out = {}
	for name, saved in pairs(card_areas or {}) do
		local live = G[name]
		if type(saved) == 'table' and type(saved.cards) == 'table' and live and live.cards then
			local list, any = {}, false
			for i = 1, #saved.cards do
				local id = ids[live.cards[i]] or 0
				list[i] = id
				any = any or id ~= 0
			end
			if any then out[name] = list end
		end
	end
	return out
end

-- Vanilla's save table for the run as it is now. Saving is switched off inside a lobby, so it
-- is switched on just for this call, and the save file write that save_run queues is undone:
-- the table is what we want, not a file.
local function vanilla_save_table()
	local handler = G.FILE_HANDLER
	local flag, file_run, file_queued = G.F_NO_SAVING, handler and handler.run, handler and handler.update_queued
	local previous = G.ARGS.save_run
	G.F_NO_SAVING = false
	G.ARGS.save_run = nil
	local ok, err = pcall(save_run)
	local saved = G.ARGS.save_run
	G.ARGS.save_run = previous
	G.F_NO_SAVING = flag
	if handler then
		handler.run, handler.update_queued = file_run, file_queued
	end
	if not ok then
		MPAPI.sendWarnMessage('run_save: save_run failed: ' .. tostring(err))
		return nil
	end
	return saved
end

local function log_sizes(raw, compressed, encoded, parts, pos)
	local line = string.format('Run save taken: raw %d bytes, compressed %d bytes, encoded %d bytes, %d part(s), after %d log events', raw, compressed, encoded, parts, pos)
	if sendInfoMessage then
		sendInfoMessage(line, MPAPI.id or 'MPAPI')
	else
		MPAPI.sendDebugMessage(line)
	end
end

-- Takes a Run save of the current match and sends it. False when there is nothing to send
-- (not in a refereed match, the log cannot be hashed, the save is too big or could not be
-- built) or the socket is down; the next Blind Select takes a new one.
function RS.take()
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and MPAPI.has_server_referee(lobby) and lobby._game.started) then return false end
	local pos, hash = MPAPI.replay.log_position()
	if not pos then return false end
	local save = vanilla_save_table()
	if not save then return false end

	local envelope = {
		v = RS.FORMAT_VERSION,
		save = save,
		mods = RS.collect_state(),
		card_ids = RS.card_ids(save.cardAreas),
		next_card_id = MPAPI.replay._next_card_id,
	}
	local ok, packed = pcall(RS.codec.pack, envelope)
	if not ok then
		MPAPI.sendWarnMessage('run_save: could not pack the save: ' .. tostring(packed))
		return false
	end
	local compressed = RS.codec.compress(packed)
	local encoded = RS.codec.to_text(compressed)
	local parts = RS.split(encoded, RS.PART_BYTES)
	if #parts > RS.MAX_PARTS then
		MPAPI.sendWarnMessage(string.format('run_save: save of %d characters needs %d parts, over the limit of %d', #encoded, #parts, RS.MAX_PARTS))
		return false
	end
	log_sizes(#packed, #compressed, #encoded, #parts, pos)

	seq = seq + 1
	local id = string.format('%s-%d', lobby._game.started.run_id, seq)
	for index, data in ipairs(parts) do
		local sent = lobby:action(MPAPI.ActionTypes.mpapi_run_save_part):send(nil, {
			run = lobby._game.started.run_id,
			id = id,
			index = index - 1,
			count = #parts,
			pos = pos,
			hash = hash,
			data = data,
		})
		if sent == false then return false end
	end
	return true
end

-- Vanilla saves the run as the Blind Select screen is built, in an event it queues. The Run
-- save is queued behind it, so it sees the same state.
if Game and Game.update_blind_select then
	local update_blind_select_ref = Game.update_blind_select
	function Game:update_blind_select(dt)
		local building = not G.STATE_COMPLETE
		update_blind_select_ref(self, dt)
		if building and G.STATE_COMPLETE and G.E_MANAGER then
			G.E_MANAGER:add_event(Event({
				trigger = 'immediate',
				blockable = false,
				no_delete = true,
				func = function()
					local ok, err = pcall(RS.take)
					if not ok then MPAPI.sendWarnMessage('run_save: ' .. tostring(err)) end
					return true
				end,
			}))
		end
	end
end
