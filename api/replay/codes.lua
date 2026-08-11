-- MPAPI.RLOG_CODE: declarative opcode definitions for the replay/log system,
-- same SMODS.GameObject:extend idiom MPAPI.GameMode (api/gamemode/definition.lua)
-- and MPAPI.ActionType (api/action/registry.lua) already use. Bundles an
-- opcode's key, its recorder-side write() call, and its playback-side
-- replay() handler into one object instead of the two being defined in
-- separate files (a record call site vs. a MPAPI.playback.register_handler
-- call) that can silently drift apart.
--
-- `key` is a raw opcode string shared VERBATIM across mods and with the
-- recorder's own carbon-stream text ("MP_RLOG: <t> play ...") -- it must NOT
-- get Steamodded's usual mod-prefix treatment (which would turn "play" into
-- "pvp_play"), so prefix_config disables key-prefixing here, the same way
-- SMODS.Language/SMODS.ObjectType/SMODS.ConsumableType do for their own
-- cross-mod-shared keys.
--
-- Versioning: there is no per-opcode version field. Every replay(args, ctx)
-- receives the recording's schema version as ctx.schema_version (see
-- api/playback/driver.lua) and branches on it directly --
-- `if ctx.schema_version >= 1 then ... end`, extended additively
-- (`if ctx.schema_version >= 2 then ... elseif ctx.schema_version >= 1 then ... end`)
-- the day a specific opcode's shape actually changes. See recorder.lua's
-- RLOG.SCHEMA_VERSION for the single global version signal this all derives
-- from.
MPAPI.RLOGCodes = MPAPI.RLOGCodes or {}

-- The real GameObject class -- MPAPI.RLOG_CODE (below) is a thin wrapper
-- around calling this, not this itself (see that wrapper's own comment for
-- why).
local RLOGCodeClass = SMODS.GameObject:extend {
	obj_table = MPAPI.RLOGCodes,
	obj_buffer = {},
	set = 'RLOGCode',
	prefix_config = { key = false },
	required_params = { 'key', 'mods', 'write', 'replay' },

	-- Registers this code's replay() under MPAPI.playback's existing
	-- per-mod-id handler registry (api/playback/registry.lua), once per
	-- listed mod_id -- but ONLY as a fallback if that (mod_id, key) pair has
	-- no handler registered yet, so a consuming mod's own playback_handlers.lua
	-- (e.g. PvP's select_blind/skip_blind/sell handlers, which add non-POV
	-- opponent-HUD projection a generic RLOG_CODE has no business knowing
	-- about) always wins over this baseline if it registers the same
	-- (mod_id, key) pair itself, whichever order the two actually run in.
	--
	-- Called directly by MPAPI.RLOG_CODE below, NOT left to Steamodded's own
	-- deferred SMODS.injectObjects(SMODS.GameObject) batch pass -- confirmed
	-- live that pass is unreliable for this: it fires once, apparently tied
	-- to whichever mod's loading triggers it first (empirically MPAPI's own,
	-- since framing_codes.lua's objects -- defined inside MPAPI -- got
	-- injected fine), NOT guaranteed to run again after a LATER mod (e.g.
	-- SPDRN's own run_transition_codes.lua) registers new RLOG_CODE objects
	-- of its own. Manually re-invoking SMODS.injectObjects(SMODS.GameObject)
	-- after boot retroactively fixed the missing handlers, proving the
	-- objects/registration were fine and only the deferred inject() call was
	-- the gap. Calling inject() ourselves, synchronously, the moment each
	-- code is defined removes the dependency on that batch pass entirely.
	inject = function(self)
		for _, mod_id in ipairs(self.mods) do
			local existing = MPAPI.playback._handlers[mod_id] and MPAPI.playback._handlers[mod_id][self.key]
			if not existing then
				MPAPI.playback.register_handler(mod_id, self.key, function(args, ctx)
					return self:replay(args, ctx)
				end)
			end
		end
	end,

	-- Call sites use `MPAPI.RLOGCodes.<key>:write(...)` instead of a raw
	-- MPAPI.replay.record(...) call. self:record() delegates straight through
	-- to the existing recorder (carbon/human dual-stream, hashing, broadcast) --
	-- it doesn't reimplement or bypass any of it.
	record = function(self, args, human)
		return MPAPI.replay.record(self.key, args, human)
	end,
}

-- MPAPI.RLOG_CODE(args) still does exactly what calling an ordinary
-- SMODS.GameObject subclass does (required_params validation, key-prefix
-- handling, duplicate-key check, registration into MPAPI.RLOGCodes) via
-- RLOGCodeClass's own __call -- this wrapper's only addition is calling
-- inject() immediately afterward instead of waiting on Steamodded's own
-- deferred batch pass (see inject's own comment above for why that's
-- required, not optional). Guarded on `o` being non-nil: __call returns
-- nothing when check_duplicate_register/check_duplicate_key short-circuits.
MPAPI.RLOG_CODE = function(args)
	local o = RLOGCodeClass(args)
	if o then o:inject() end
	return o
end
