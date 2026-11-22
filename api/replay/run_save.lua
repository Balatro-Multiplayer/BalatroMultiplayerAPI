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
-- (the server gives it back whole). Refused: a text the codec cannot read, a newer format
-- than this client knows, a save without the parts a start needs.
function RS.decode(text)
	local ok, envelope = pcall(function()
		local value = RS.codec.unpack(RS.codec.decompress(RS.codec.from_text(text)))
		if type(value) ~= 'table' then error('not a table') end
		if value.v ~= RS.FORMAT_VERSION then
			error(string.format('format version %s, this client reads %s', tostring(value.v), tostring(RS.FORMAT_VERSION)))
		end
		if type(value.save) ~= 'table' then error('no save table') end
		if type(value.save.GAME) ~= 'table' then error('the save has no GAME') end
		return value
	end)
	if not ok then return nil, tostring(envelope) end
	return envelope
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

-- The Run save of the current match as one text, with the log position and hash it was taken at.
-- nil when there is nothing to save (not in a refereed match, the lobby is catching up, the log
-- cannot be hashed, the save could not be built or packed).
local function build_text()
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and MPAPI.has_server_referee(lobby) and lobby._game.started) then return nil end
	-- A client that is replaying its log is not at the state its recorder's position names.
	if lobby._catching_up then return nil end
	local pos, hash = MPAPI.replay.log_position()
	if not pos then return nil end
	local save = vanilla_save_table()
	if not save then return nil end

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
		return nil
	end
	local compressed = RS.codec.compress(packed)
	local encoded = RS.codec.to_text(compressed)
	return { text = encoded, pos = pos, hash = hash, raw = #packed, compressed = #compressed, lobby = lobby }
end

-- Takes a Run save of the current match, keeps it as the local copy and sends it. False when there
-- is nothing to send (not in a refereed match, the lobby is catching up, the log cannot be hashed,
-- the save is too big or could not be built) or the socket is down; the next Blind Select takes a
-- new one.
function RS.take()
	local built = build_text()
	if not built then return false end
	RS.write_local(built)
	local lobby, encoded, pos, hash = built.lobby, built.text, built.pos, built.hash
	local parts = RS.split(encoded, RS.PART_BYTES)
	if #parts > RS.MAX_PARTS then
		MPAPI.sendWarnMessage(string.format('run_save: save of %d characters needs %d parts, over the limit of %d', #encoded, #parts, RS.MAX_PARTS))
		return false
	end
	log_sizes(built.raw, built.compressed, #encoded, #parts, pos)

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

-- The local copy of the Run save: the same text take() sends, kept in one file per player of the
-- save folder (windows on one machine share it) and replaced by every local save. It is not
-- vanilla's Continue file: a lobby run must never be offered as a single-player Continue. A rejoin
-- reads it next to the server's copy (MPAPI.playback.pick_rejoin_start) and starts from the newer.
local function local_file(player)
	return 'mpapi_local_run_save_' .. tostring(player):gsub('[^%w_-]', '_') .. '.txt'
end

-- { run, player, pos, hash, data } from a file text (first line "run player pos hash"), or nil.
function RS.parse_local(text)
	if type(text) ~= 'string' then return nil end
	local line, data = text:match('^([^\n]*)\n(.*)$')
	if not line then return nil end
	local run, player, pos, hash = line:match('^(%S+) (%S+) (%d+) (%S+)$')
	if not run or data == '' then return nil end
	return { run = run, player = player, pos = tonumber(pos), hash = hash, data = data }
end

-- This player's local copy as a parsed table, or nil when there is none, it is unreadable or it
-- was written for another player.
function RS.read_local()
	local player = MPAPI.get_replay_player_id()
	if not player then return nil end
	local ok, text = pcall(love.filesystem.read, local_file(player))
	if not ok then return nil end
	local parsed = RS.parse_local(text)
	if parsed and parsed.player ~= tostring(player) then return nil end
	return parsed
end

-- Deletes this player's local copy (a rejoin that went live no longer needs it).
function RS.clear_local()
	local player = MPAPI.get_replay_player_id()
	if not player then return end
	pcall(love.filesystem.remove, local_file(player))
end

-- Writes a built save as this player's local copy. False when the player is unknown or the write failed.
function RS.write_local(built)
	local player = MPAPI.get_replay_player_id()
	if not player then return false end
	local run = built.lobby._game.started.run_id
	local text = string.format('%s %s %d %s' .. '\n' .. '%s', tostring(run), tostring(player), built.pos, built.hash, built.text)
	local ok, written, reason = pcall(love.filesystem.write, local_file(player), text)
	if not ok or not written then
		MPAPI.sendWarnMessage('run_save: the local save was not written: ' .. tostring(ok and reason or written))
		return false
	end
	return true
end

-- Takes a Run save of the current match into the local file only; nothing is sent. False when
-- there is nothing to save (same cases as take) or the write failed.
function RS.take_local()
	local built = build_text()
	if not built then return false end
	return RS.write_local(built)
end

-- A mod can say "not now" at a save point (register_save_wait: is_waiting() returns true while it
-- has work the save must not miss). Only the hook of the current lobby's mod is asked. The save is
-- then taken when that mod calls save_now() and no longer says not now, and only if no newer
-- save-point screen has started since. Each screen gets the next number as it starts to build; a
-- number, not G.STATE, because the game can leave a screen and come back to the same state.
RS._save_waits = RS._save_waits or {}
local latest_save_point = 0
local waiting_save_point = nil
local waiting_state = nil

function RS.register_save_wait(mod_id, is_waiting)
	RS._save_waits[mod_id] = is_waiting
end

-- Numbers a save-point screen as it starts to build.
function RS.start_save_point()
	latest_save_point = latest_save_point + 1
	return latest_save_point
end

-- Forgets a put-off save: the lobby was left or the run ended.
function RS.clear_wait()
	waiting_save_point = nil
end

-- Only the hook of the current lobby's mod is asked: another mod's leftover state holds nothing back.
local function lobby_mod_waiting()
	local lobby = MPAPI.get_current_lobby()
	local is_waiting = lobby and RS._save_waits[lobby.mod_id]
	if not is_waiting then
		return false
	end
	local ok, waiting = pcall(is_waiting)
	if not ok then
		MPAPI.sendWarnMessage('run_save: wait hook of ' .. tostring(lobby.mod_id) .. ' failed: ' .. tostring(waiting))
		return false
	end
	return waiting and true or false
end

-- Called once the save-point screen numbered `save_point` is built. Takes the save now, or puts it
-- off when a mod says not now. A screen that a newer one has replaced takes nothing.
function RS.at_save_point(save_point)
	waiting_save_point = nil
	if save_point ~= latest_save_point then return false end
	if lobby_mod_waiting() then
		waiting_save_point = save_point
		waiting_state = G and G.STATE
		return false
	end
	return RS.take()
end

-- A mod says now: takes the save put off by at_save_point once the lobby's mod no longer waits and the
-- game is still at that save point (same number, same state, screen built). While it still waits,
-- the save stays put off.
function RS.save_now()
	if waiting_save_point == nil or waiting_save_point ~= latest_save_point or lobby_mod_waiting() then return false end
	if not (G and G.STATE == waiting_state and G.STATE_COMPLETE) then return false end
	waiting_save_point = nil
	return RS.take()
end

-- Vanilla saves the run as the Blind Select screen is built, in an event it queues. The Run
-- save is queued behind it, so it sees the same state. It is blockable like vanilla's: the
-- start of a run queues delayed events (the Ghost Deck's Hex), and a save that ran ahead of them
-- would lack what they add.
if Game and Game.update_blind_select then
	local update_blind_select_ref = Game.update_blind_select
	function Game:update_blind_select(dt)
		local building = not G.STATE_COMPLETE
		update_blind_select_ref(self, dt)
		if building and G.STATE_COMPLETE and G.E_MANAGER then
			local save_point = RS.start_save_point()
			G.E_MANAGER:add_event(Event({
				trigger = 'immediate',
				no_delete = true,
				func = function()
					local ok, err = pcall(RS.at_save_point, save_point)
					if not ok then MPAPI.sendWarnMessage('run_save: ' .. tostring(err)) end
					return true
				end,
			}))
		end
	end
end
