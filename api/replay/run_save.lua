-- MPAPI.run_save: takes a Run save at the points where vanilla saves a run on a Blind Select or
-- shop screen of a server-refereed match, and sends it to the server in parts (the
-- mpapi_run_save_part action; BalatroMultiplayerServer nakama/src/actions/run_save.ts holds the
-- same part format and limits).
--
-- The save points are four of vanilla's save_run calls, each followed by a call to
-- MPAPI.run_save.at_save_point() (lovely/run_save_points.toml): the Blind Select build, a skip,
-- a boss reroll, and the shop build. No other save_run takes a Run save. A shop is saved only
-- for a mod whose rejoin hooks declare run_save_screens = { SHOP = true }.
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
RS.FORMAT_VERSION = 2

-- Why a rejoin or a spectator start does not use a Run save and plays the whole log instead.
-- HASH_MISMATCH and BEYOND_LOG are the server's own words for a save it held back
-- (runSaveSkipped); the rest come from the client.
RS.SKIP = {
	NOT_SUPPORTED = 'not_supported',
	NO_SAVE = 'no_save',
	HASH_MISMATCH = 'hash_mismatch',
	BEYOND_LOG = 'beyond_log',
	EARLIER_RUN = 'earlier_run',
	UNREADABLE = 'unreadable',
	LOAD_FAILED = 'load_failed',
	START_TIMEOUT = 'start_timeout',
}

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
		-- The way back. unpack refuses code in the text when the sandboxed unpack is there.
		from_text = function(text)
			return love.data.decode('string', 'base64', text)
		end,
		decompress = function(binary)
			return love.data.decompress('string', 'deflate', binary)
		end,
		unpack = function(text)
			return MPAPI.str_unpack_checked(text)
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

-- The envelope a Run save text holds, or nil and the reason. The text is what take sent
-- (the server gives it back whole). Refused: a text the codec cannot read, any format but the
-- one this client writes, a save without the parts a start needs, a save of any screen but
-- Blind Select or the shop (save.STATE, which vanilla writes).
function RS.decode(text)
	local ok, envelope = pcall(function()
		local value = RS.codec.unpack(RS.codec.decompress(RS.codec.from_text(text)))
		if type(value) ~= 'table' then error('not a table') end
		if value.v ~= RS.FORMAT_VERSION then
			error(string.format('format version %s, this client reads %s', tostring(value.v), tostring(RS.FORMAT_VERSION)))
		end
		if type(value.save) ~= 'table' then error('no save table') end
		if type(value.save.GAME) ~= 'table' then error('the save has no GAME') end
		if RS.screen_of(value) == nil then error('the save is of screen ' .. tostring(value.save.STATE) .. ', not Blind Select or the shop') end
		return value
	end)
	if not ok then return nil, tostring(envelope) end
	return envelope
end

-- 'BLIND_SELECT' or 'SHOP', the screen a decoded Run save was taken at, or nil for any other.
function RS.screen_of(envelope)
	local state = envelope and type(envelope.save) == 'table' and envelope.save.STATE
	if state == nil then return nil end
	if state == G.STATES.BLIND_SELECT then return 'BLIND_SELECT' end
	if state == G.STATES.SHOP then return 'SHOP' end
	return nil
end

-- Puts a decoded Run save's extras back, after the game has started from its save table:
-- each mod's state through its load hook, and the recorder's card ids into `resolver` (a
-- playback resolver state, MPAPI.replay.new_resolver_state), so the events that follow find
-- the cards they name. True, or false and the reason (the caller then plays the whole log).
function RS.restore(envelope, resolver)
	for mod_id, state in pairs(envelope.mods or {}) do
		local hooks = RS._state_hooks[mod_id]
		if hooks and hooks.load then
			local ok, err = pcall(hooks.load, state)
			if not ok then return false, 'state hook of ' .. mod_id .. ' failed to load: ' .. tostring(err) end
		end
	end
	for name, list in pairs(envelope.card_ids or {}) do
		local area = G[name]
		for i, id in ipairs(list) do
			local card = area and area.cards and area.cards[i]
			if id ~= 0 and card then
				resolver.by_id[id] = card
				resolver.assigned[card] = true
			end
		end
	end
	-- Vanilla's Card:load restores each card's saved sort_id but never touches the counter that
	-- Card:init counts up from, so a card made after the load could take a loaded card's id.
	for _, area in pairs(G.I.CARDAREA) do
		for _, card in ipairs(area.cards or {}) do
			if card.sort_id and card.sort_id > G.sort_id then G.sort_id = card.sort_id end
		end
	end
	return true
end

-- The next Game:start_run starts from this Run save's save table (vanilla's own way of
-- continuing a run) instead of a new run. Used once; unstage_load drops it unused.
function RS.stage_load(envelope)
	RS._staged = envelope
end

function RS.unstage_load()
	RS._staged = nil
end

-- True while a Run save waits for the next Game:start_run.
function RS.is_staged()
	return RS._staged ~= nil
end

if Game and Game.start_run then
	local start_run_ref = Game.start_run
	function Game:start_run(args)
		local staged = RS._staged
		if staged then
			RS._staged = nil
			local from_save = {}
			for k, v in pairs(args or {}) do from_save[k] = v end
			from_save.savetext = staged.save
			args = from_save
		end
		return start_run_ref(self, args)
	end
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
-- (not in a refereed match, the lobby is catching up, the log cannot be hashed, the save is too big or could not be
-- built) or the socket is down; the next save point takes a new one.
function RS.take()
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and MPAPI.has_server_referee(lobby) and lobby._game.started) then return false end
	-- A client that is replaying its log is not at the state its recorder's position names.
	if lobby._catching_up then return false end
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

-- Called right after vanilla's save_run at each save point (lovely/run_save_points.toml), in the
-- same event or callback, so the Run save sees the state vanilla saved. Takes a save at Blind
-- Select, and at a built shop when the lobby's mod declares it can load one. Calls from
-- anywhere else are not save points: nothing else calls this, whatever calls save_run.
function RS.at_save_point()
	local ok, err = pcall(function()
		local lobby = MPAPI.get_current_lobby()
		if not lobby then return end
		if G.STATE == G.STATES.BLIND_SELECT then
			RS.take()
		elseif G.STATE == G.STATES.SHOP and MPAPI.playback.shop_is_built() then
			local hooks = MPAPI.playback._rejoin_hooks and MPAPI.playback._rejoin_hooks[lobby.mod_id]
			local screens = hooks and hooks.run_save_screens
			if screens and screens.SHOP == true then RS.take() end
		end
	end)
	if not ok then MPAPI.sendWarnMessage('run_save: ' .. tostring(err)) end
end
