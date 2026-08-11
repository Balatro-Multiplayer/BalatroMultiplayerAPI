-- MPAPI.replay: dual-stream, deterministic, mod-agnostic action-log recorder.
-- Sibling to api/replay/api.lua (download/list/spectate) and api/playback/*
-- (dispatch/timeline) -- this file is the recording side of the same
-- record -> transport -> download -> dispatch/timeline pipeline, generic to
-- ANY consuming mod (PvP today, SPDRN or any future one for free) the same
-- way api/playback/registry.lua's opcode dispatch already is: MPAPI has no
-- idea what a "buy" or "net_pizza" opcode actually means, only how to
-- record/hash/transport the {t, opcode, args} tuple. A consuming mod's own
-- game-logic overrides are the only place opcode meaning lives -- e.g.
-- BalatroMultiplayerPvP's overrides/game.lua calling MPAPI.replay.record
-- (aliased there as PVP.RLOG, see lib/replay_log.lua) at its own "buy"/
-- "sell"/etc. call sites.
--
-- Two streams are emitted from the SAME instrumentation points so they stay
-- event-for-event aligned (shared elapsed-ms timestamp). Both go into the
-- ordinary Lovely log, distinguished only by a line prefix so parsers know what
-- to read -- there is no separate file.
--
--   1. Carbon-copy (replay) stream  -- prefix "MP_RLOG:". Positional, no names:
--      "MP_RLOG: 5123 buy 1 2" means "at 5.123s into the run, buy shop area 1,
--      slot 2". Indiscriminate, so modded content is just "slot N" and replays
--      across mods for free. This is the only truly replayable stream. The
--      block is framed by a MANIFEST header and an END + CHK trailer (also
--      under the MP_RLOG: prefix).
--
--   2. Human-readable stream  -- prefix "Client sent message:" (the existing
--      format the website parser already reads). "Client sent message: action:
--      boughtCardFromShop,card:Blueprint,cost:4".
--
-- record() is the single emitter for both lines, so a consuming mod's own
-- per-action overrides don't log the human line themselves -- they pass the
-- payload to record().
--
-- Timestamps: each event's leading field is `t`, milliseconds elapsed since the
-- manifest's `start_epoch_ms` (captured once, via a monotonic clock) -- not a
-- bare sequence counter. This keeps per-event numbers small (a few digits for a
-- multi-minute match, instead of repeating a 13-digit absolute epoch stamp on
-- every line) while still being monotonically non-decreasing, so it doubles as
-- the same ordering key a sequence number would give, and additionally carries
-- the real elapsed-time information anti-cheat plausibility checks and
-- reconnect tail-requests both need. Matches the MQTT design doc's own §26.1
-- `t` field convention (ms since match start), so this format and the server's
-- eventual event schema agree instead of diverging.
--
-- At end_run both streams are hashed and broadcast in the CHK trailer. The
-- carbon stream's hash (carbon_hash) is a real SHA-256 over a canonical JSON
-- re-encoding of its own {t, opcode, args} events (see canonical_hash_input),
-- not over the text lines themselves -- this is what the server independently
-- recomputes from its own buffered events and compares against at match-
-- resolve time (matchmaking.service.ts's evaluateAntiCheat, Phase 8) to flag a
-- tampered log. The human stream's hash (human_hash) stays on a cheap local
-- Adler-style checksum -- it's never server-verified, just a local corruption
-- check. Full re-simulation anti-cheat remains future work.
--
-- Live transport: a consuming mod is expected to also broadcast every event
-- (including the MANIFEST/END/CHK framing lines) in real time over its own
-- MPAPI ActionType by calling RLOG.register_broadcaster(mod_id, fn) (see
-- BalatroMultiplayerPvP/pvp_api/replay_log_actions.lua or
-- BalatroMultiplayerSpeed/objects/replay_log/actions.lua for reference
-- implementations, registering the "pvp_log_event"/"spdrn_log_event" Action-
-- Types respectively) -- one broadcast per event, not batched, so a
-- server-side buffer (or a spectator) sees each line as it happens.
-- RLOG.broadcast_event itself dispatches by the CURRENT lobby's mod_id, not a
-- single mutable slot: MPAPI.replay is one shared singleton, so if it were a
-- single function a second consuming mod's registration would silently
-- clobber the first mod's (whichever mod's file happened to load last would
-- "win" for every game afterward, regardless of which mod's lobby was
-- actually live) -- confirmed as a real bug the first time a second consumer
-- (SPDRN) was added alongside PvP in the same install. The local carbon/human
-- text lines into the
-- Lovely log are unaffected either way -- a missing broadcaster just no-ops,
-- local logging still works (e.g. under the headless test harness).
MPAPI.replay = MPAPI.replay or {}
local RLOG = MPAPI.replay

RLOG.CARBON_PREFIX = "MP_RLOG:" -- positional / replay stream
RLOG.HUMAN_PREFIX = "Client sent message:" -- human-readable stream (website-compatible)

-- Schema version of the MANIFEST/event format itself (bump on breaking changes
-- to what the server/replay-parser needs to understand, independent of mod_version).
-- v2: card-referencing events carry full card identity inline -- see
-- RLOG.card_ref.
RLOG.SCHEMA_VERSION = 2

-- Required manifest keys; begin_run warns if any are missing. api_version/
-- mod_version/start_epoch_ms are stamped by begin_run itself (see below), not
-- required from the caller.
RLOG.REQUIRED_MANIFEST_KEYS = { "seed", "ruleset", "gamemode", "deck", "stake" }

RLOG._start_ms = nil -- monotonic-clock ms at begin_run, source of truth for each event's `t`
RLOG._fallback_seq = 0 -- ms-surrogate counter when no monotonic clock is available (e.g. tests)
RLOG._carbon_buffer = {} -- the action "MP_RLOG: <t> ..." lines, hashed at end
RLOG._carbon_full = {} -- the full carbon block (manifest + actions + END + CHK), sent to the server
RLOG._human_buffer = {} -- the "Client sent message: ..." lines, hashed at end
-- {t, opcode, args} tuples for gameplay events only -- populated exclusively by
-- RLOG.record, so the MANIFEST/END/CHK framing lines (emitted directly via
-- emit_carbon, bypassing record) are never in here. Used at end_run to compute
-- a canonical SHA-256 hash the server can independently reproduce (see
-- canonical_hash_input below) -- kept separate from _carbon_buffer because that
-- one holds pre-formatted text lines, not the structured values a hash needs.
RLOG._structured_events = {}
RLOG._run_active = false
RLOG._manifest = nil
RLOG._force_active = false -- test hook: bypass the lobby gate

-- Per-run card identity dictionary (see RLOG.card_ref below). Keyed by the
-- Card object's own table reference -- not card.sort_id, which is a per-run
-- counter unsuitable for cross-referencing. Reset every begin_run so ids
-- restart at 1 each match.
RLOG._card_ids = {}
RLOG._next_card_id = 0

-- Per-run correlation id (embedded in the manifest); not used for batching
-- anymore (a consuming mod's own transport broadcasts every event live,
-- individually), just a friendly local identifier for this run instance.
RLOG._game_id = nil -- generated in begin_run

-------------------------------------------------------------------------------
-- Gate
-------------------------------------------------------------------------------

-- Only real multiplayer games log. Practice and preview/simulation modes have
-- no active lobby, so they never emit.
function RLOG.is_active()
	if RLOG._force_active then return true end
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and lobby.code) then return false end
	return true
end

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

-- Mirrors a consuming mod's own live-transport normalize_args (nil stays nil,
-- a table stays a table, a bare scalar becomes a single-element array) -- see
-- BalatroMultiplayerPvP/pvp_api/replay_log_actions.lua for the reference
-- implementation. Applied when building _structured_events (not to args
-- generally -- fmt_args and the carbon text line still use the original,
-- unwrapped args) so the hash input matches EXACTLY what the wire transport
-- sends and the server buffers. Without this, a bare-scalar opcode would hash
-- differently locally (raw scalar) than what the server observes (wrapped in
-- a 1-element array by the transport's own normalize_args before broadcast),
-- so every clean run would spuriously flag as a hash mismatch.
local function normalize_for_hash(args)
	if args == nil then return nil end
	if type(args) == "table" then return args end
	return { args }
end

-- Format an opcode's args into the positional arg string.
-- Each token is either a scalar -> "1" or a list -> dot-joined "1.3.5".
-- A bare scalar/string is treated as a single token.
local function fmt_args(args)
	if args == nil then return "" end
	if type(args) ~= "table" then return tostring(args) end
	local parts = {}
	for _, tok in ipairs(args) do
		if type(tok) == "table" then
			local sub = {}
			for _, v in ipairs(tok) do
				sub[#sub + 1] = tostring(v)
			end
			parts[#parts + 1] = table.concat(sub, ".")
		else
			parts[#parts + 1] = tostring(tok)
		end
	end
	return table.concat(parts, " ")
end

local function emit(msg)
	sendTraceMessage(msg, "MULTIPLAYER")
end

-- Friendly per-run correlation id, embedded in the manifest for local
-- debugging/display -- not load-bearing for the live transport (see
-- RLOG._game_id's declaration above).
local function new_game_id(manifest)
	local lobby = (manifest and manifest.lobby_code) or "nolobby"
	local who = (manifest and manifest.player) or "?"
	return string.format("%s-%s-%d-%d", tostring(lobby), tostring(who), os.time(), math.random(100000, 999999))
end

-- Milliseconds elapsed since begin_run, for each event's `t`. Falls back to a
-- plain incrementing counter (behaving like a sequence number) when
-- love.timer isn't available, e.g. under the headless test harness -- so
-- `t` is still monotonically non-decreasing even without a real clock.
local function elapsed_ms()
	if RLOG._start_ms == nil then
		RLOG._fallback_seq = RLOG._fallback_seq + 1
		return RLOG._fallback_seq
	end
	return math.floor(love.timer.getTime() * 1000 - RLOG._start_ms + 0.5)
end

-- mod_id -> broadcaster fn, populated by each consuming mod's own transport
-- wiring via RLOG.register_broadcaster (see the "Live transport" doc comment
-- above for why this is a registry keyed by mod_id rather than a single slot).
RLOG._broadcasters = {}

function RLOG.register_broadcaster(mod_id, fn)
	RLOG._broadcasters[mod_id] = fn
end

-- Dispatches to whichever mod owns the CURRENT lobby. No-ops with no lobby
-- (practice mode, headless tests) or no broadcaster registered for that mod
-- (a consuming mod that hasn't wired transport up yet) -- local carbon/human
-- logging is unaffected either way.
function RLOG.broadcast_event(t, opcode, args)
	local lobby = MPAPI.get_current_lobby()
	local fn = lobby and RLOG._broadcasters[lobby.mod_id]
	if fn then fn(t, opcode, args) end
end

-- Emit a carbon-stream line: tee to the Lovely log, accumulate it into the full
-- local block, AND broadcast the structured (t, opcode, args) form live via
-- RLOG.broadcast_event.
local function emit_carbon(msg, t, opcode, args)
	RLOG._carbon_full[#RLOG._carbon_full + 1] = msg
	sendTraceMessage(msg, "MULTIPLAYER")
	RLOG.broadcast_event(t, opcode, args)
end

-- Encodes one {t, opcode, args} tuple as a JSON array literal, built manually
-- rather than via json.encode(ev) on a Lua table -- args is sometimes nil
-- (e.g. reroll, cashout), and a trailing nil in a positional Lua table makes
-- `#`/array-vs-object detection undefined, which a generic table encoder can't
-- be trusted to handle consistently. `t` and `opcode` are scalars (a number
-- and a string), and every args value a consuming mod passes is nil, a bare
-- scalar, or a plain positional array/list, never a table with string keys,
-- so nothing here has Lua/JS pairs()-order ambiguity to worry about; only the
-- outer 3-element shape does.
local function encode_event_tuple(ev)
	local json = require("json")
	local args_json = ev.args == nil and "null" or json.encode(ev.args)
	return string.format("[%d,%s,%s]", ev.t, json.encode(ev.opcode), args_json)
end

-- Canonical JSON-array encoding of every gameplay event (see RLOG._structured_events),
-- used as the SHA-256 input for RLOG.end_run's CHK line -- independently
-- reproducible server-side (Node's JSON.stringify over the same tuple shape)
-- without needing to match Lua's dict key-iteration order, since the whole
-- input is array-shaped end to end.
local function canonical_hash_input()
	local parts = {}
	for _, ev in ipairs(RLOG._structured_events) do
		parts[#parts + 1] = encode_event_tuple(ev)
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

-- Cheap Adler-style checksum for the human stream (never server-verified,
-- purely a local corruption check) -- kept private to this file rather than
-- exposed as a general-purpose MPAPI hash utility, since it has exactly one
-- caller (end_run below).
local function cheap_hash(str)
	local a, b = 1, 0
	for i = 1, #str do
		a = (a + str:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return string.format("%08x", b * 65536 + a)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Record one state-affecting action. Emits the carbon (positional) line and,
-- when a human payload is provided, the mirrored human line -- both into the
-- Lovely log tagged with the same elapsed-ms timestamp `t`.
--   opcode : string, e.g. "buy"
--   args   : nil | scalar | list of tokens (scalar or sub-list); see fmt_args
--   human  : nil | string payload in the existing "action:key,..." format
function RLOG.record(opcode, args, human)
	if not RLOG.is_active() or not RLOG._run_active then return end

	local t = elapsed_ms()

	local argstr = fmt_args(args)
	local cline = RLOG.CARBON_PREFIX .. " " .. t .. " " .. opcode .. (argstr ~= "" and (" " .. argstr) or "")
	RLOG._carbon_buffer[#RLOG._carbon_buffer + 1] = cline
	RLOG._structured_events[#RLOG._structured_events + 1] =
		{ t = t, opcode = opcode, args = normalize_for_hash(args) }
	emit_carbon(cline, t, opcode, args)

	if human ~= nil and human ~= "" then
		local hline = RLOG.HUMAN_PREFIX .. " " .. human
		RLOG._human_buffer[#RLOG._human_buffer + 1] = hline
		emit(hline)
	end
end

-- Compact, self-describing reference to a card's current identity, for
-- embedding in card-referencing events' args (play/discard/sell/buy/
-- open_pack/voucher/pack_pick/use/pack_skip/reorder, etc.). Two shapes,
-- disambiguated by the SIGN of the first element (no lookahead/length-
-- inference needed):
--
--   already-seen : { id, tag, tag, ... }                    -- id > 0
--   first-seen   : { -id, kind, ident..., tag, tag, ... }    -- id negative
--
-- `kind`/`ident` (first-seen only) identify WHAT the card is: "pc" + suit,
-- value for a playing card; otherwise card.ability.set verbatim (Balatro's
-- own type name -- "Joker", "Tarot", "Planet", "Spectral", "Voucher"),
-- falling back to "j" if that's somehow unset, + the card's SMODS center key.
--
-- `tag...` (0-3 elements, on EVERY reference, first-seen or not, since
-- enhancement/edition/seal can mutate mid-run -- Glass Joker, Vampire, Hex,
-- spectral cards, etc.): "e:"+enhancement key (playing cards only, omitted
-- when the card has none, i.e. its center is "c_base"), "ed:"+edition type
-- (omitted when none), "s:"+seal (playing cards only, omitted when none).
-- Sparse by construction, and reuses Balatro/SMODS' own native vocabulary
-- rather than a custom enum -- readable without a separate legend, and no
-- less compressible under gzip (these short strings repeat across thousands
-- of events; LZ77 turns repeats into cheap back-references either way).
--
-- Pure Card-object introspection, no consuming-mod knowledge required -- any
-- mod recording card-referencing events (PvP, SPDRN, ...) can call this
-- directly.
function RLOG.card_ref(card)
	if not card then return nil end

	local id = RLOG._card_ids[card]
	local first_seen = id == nil
	if first_seen then
		RLOG._next_card_id = RLOG._next_card_id + 1
		id = RLOG._next_card_id
		RLOG._card_ids[card] = id
	end

	-- Every Card object carries a non-nil `.base` table regardless of type
	-- (Jokers/Tarots/etc. included) -- suit/value presence is what actually
	-- distinguishes a playing card, not base's mere existence.
	local is_playing_card = card.base and card.base.suit and card.base.value

	local ref
	if not first_seen then
		ref = { id }
	elseif is_playing_card then
		ref = { -id, "pc", card.base.suit, card.base.value }
	elseif card.config and card.config.center and card.config.center.key then
		local kind = (card.ability and card.ability.set) or "j"
		ref = { -id, kind, card.config.center.key }
	else
		ref = { -id, "?" } -- defensive; shouldn't happen at any real call site
	end

	if is_playing_card and card.config and card.config.center and card.config.center.key ~= "c_base" then
		ref[#ref + 1] = "e:" .. card.config.center.key
	end
	if card.edition and card.edition.type then ref[#ref + 1] = "ed:" .. card.edition.type end
	if card.seal then ref[#ref + 1] = "s:" .. card.seal end

	return ref
end

-- Parallel-array helper for play/discard/pack_pick-targets/use-targets-style
-- events: given 1-based `indices` into `area` (defaults to G.hand), returns
-- one RLOG.card_ref per index, same order. Must be called BEFORE the
-- underlying vanilla function consumes/moves the cards.
function RLOG.card_refs(indices, area)
	area = area or (G and G.hand)
	local out = {}
	for _, i in ipairs(indices or {}) do
		local card = area and area.cards and area.cards[i]
		if card then out[#out + 1] = RLOG.card_ref(card) end
	end
	return out
end

-- Start a new game's block: reset counters/buffers and emit the manifest header.
function RLOG.begin_run(manifest)
	manifest = manifest or {}

	for _, key in ipairs(RLOG.REQUIRED_MANIFEST_KEYS) do
		if manifest[key] == nil then
			sendWarnMessage("RLOG: manifest missing required key '" .. key .. "'", "MULTIPLAYER")
		end
	end

	-- Stamped here, not required from the caller: schema/mod versions (for a
	-- server/parser to know how to read this block) and the wall-clock epoch
	-- each event's elapsed-ms `t` is relative to. os.time() is second-precision
	-- (fine for a "when did this match start" record) -- per-event elapsed time
	-- itself comes from the monotonic love.timer clock captured just below, not
	-- from this coarser epoch stamp.
	manifest.schema_version = manifest.schema_version or RLOG.SCHEMA_VERSION
	if manifest.api_version == nil and SMODS and SMODS.Mods and SMODS.Mods["MultiplayerAPI"] then
		manifest.api_version = SMODS.Mods["MultiplayerAPI"].version
	end
	manifest.start_epoch_ms = manifest.start_epoch_ms or (os.time() * 1000)

	RLOG._start_ms = (love and love.timer and love.timer.getTime) and (love.timer.getTime() * 1000) or nil
	RLOG._fallback_seq = 0
	RLOG._carbon_buffer = {}
	RLOG._carbon_full = {}
	RLOG._human_buffer = {}
	RLOG._structured_events = {}
	RLOG._manifest = manifest
	RLOG._run_active = true
	RLOG._card_ids = {}
	RLOG._next_card_id = 0

	-- Friendly local correlation id for this run instance (see the RLOG._game_id
	-- declaration above -- no longer used for batching).
	RLOG._game_id = new_game_id(manifest)
	manifest.game_id = RLOG._game_id

	local json = require("json")
	emit_carbon(RLOG.CARBON_PREFIX .. " MANIFEST " .. json.encode(manifest), 0, "manifest", manifest)
end

-- Close the current game's block: emit the END line, hash each stream, and emit
-- the CHK trailer. The hashes are returned for a future result-report step to
-- submit (see Phase 8/anti-cheat) -- there's no separate "submit the whole
-- block" step, since the server-side buffer already has every event from the
-- live broadcasts and independently recomputes carbon_hash itself
-- (matchmaking.service.ts's evaluateAntiCheat) for comparison against this
-- value. carbon_hash is a real SHA-256 (love.data.hash) over
-- canonical_hash_input's positional-tuple JSON -- deliberately NOT over
-- carbon_str's text lines, since a byte-identical text re-formatting is much
-- harder to guarantee cross-language than re-encoding the same JSON tuples.
-- human_hash stays on the cheap Adler-style cheap_hash -- it's never
-- server-verified, purely a local corruption check on the website-compatible
-- stream.
function RLOG.end_run(outcome)
	if not RLOG._run_active then return end

	local json = require("json")
	local t_end = elapsed_ms()
	emit_carbon(RLOG.CARBON_PREFIX .. " END " .. json.encode(outcome or {}), t_end, "end", outcome or {})

	local carbon_str = table.concat(RLOG._carbon_buffer, "\n")
	local human_str = table.concat(RLOG._human_buffer, "\n")
	local carbon_hash = love.data.encode("string", "hex", love.data.hash("sha256", canonical_hash_input()))
	local human_hash = cheap_hash(human_str)
	local bytes = #carbon_str + #human_str

	local chk_args = { carbon = carbon_hash, human = human_hash, bytes = bytes }
	emit_carbon(
		string.format("%s CHK v1 carbon=%s human=%s bytes=%d", RLOG.CARBON_PREFIX, carbon_hash, human_hash, bytes),
		elapsed_ms(),
		"chk",
		chk_args
	)

	RLOG._run_active = false
	return carbon_hash, human_hash
end
