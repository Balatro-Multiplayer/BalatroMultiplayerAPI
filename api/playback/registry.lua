-- §22.2/§22.3: generic, mod-agnostic opcode dispatch for match replay/spectate
-- playback. Same idiom as MPAPI.register_mod_isolation (api/layers/pool_gating.lua)
-- and the Trigger Contexts dispatch (api/context/opponent.lua, §18.2): a
-- platform-neutral registry that a consuming mod (PvP, or any future one)
-- registers its own per-opcode handlers into, since MPAPI itself has no idea
-- what a "buy" or "net_pizza" opcode actually means to apply -- only the mod
-- that recorded it does.
MPAPI.playback = MPAPI.playback or {}
MPAPI.playback._handlers = MPAPI.playback._handlers or {}

-- fn(args, ctx) where ctx = {t, player_id, is_pov, driver}. is_pov is true when
-- this event's player_id is the driver's chosen point-of-view player (see
-- driver.lua) -- a handler typically applies the real action for the POV and
-- projects a lighter HUD-only update for everyone else.
function MPAPI.playback.register_handler(mod_id, opcode, fn)
	MPAPI.playback._handlers[mod_id] = MPAPI.playback._handlers[mod_id] or {}
	MPAPI.playback._handlers[mod_id][opcode] = fn
end

-- Default-deny: an unregistered opcode is a debug-logged no-op, not a crash --
-- matches this codebase's existing default-deny philosophy (pool_gating.lua's
-- warn_if_ungated). Framing opcodes emitted by the recorder itself (manifest/
-- end/chk -- see api/replay/recorder.lua) are expected to be
-- registered like any other opcode if a consumer wants to react to them (e.g.
-- to seed initial run state from "manifest"), not treated specially here.
function MPAPI.playback.dispatch(mod_id, opcode, args, ctx)
	local mod_handlers = mod_id and MPAPI.playback._handlers[mod_id]
	local fn = mod_handlers and mod_handlers[opcode]
	if not fn then
		MPAPI.sendDebugMessage(
			'MPAPI.playback: no handler for ' .. tostring(mod_id) .. '.' .. tostring(opcode) .. ' (ignored)'
		)
		return
	end
	return fn(args, ctx)
end

MPAPI.playback._launchers = MPAPI.playback._launchers or {}

-- Registers a mod's own "play this run's own replay" entry point, keyed by
-- mod_id -- the SAME mod_id a RunRow's own `modId` field carries (see
-- MPAPI.replay.list_mine/api/replay/api.lua), i.e. whatever mod_id that mod
-- passes to MPAPI.create_lobby/create_local_lobby, NOT the separate literal
-- mod_id string ('pvp', etc.) a consuming mod may choose for its own
-- register_handler/dispatch opcode namespace above -- those are unrelated.
-- Same rationale as register_handler: MPAPI has no idea how to bootstrap a
-- seeded local run for any given mod's gamemode, only the mod that recorded
-- it does.
function MPAPI.playback.register_launcher(mod_id, launch_fn)
	MPAPI.playback._launchers[mod_id] = launch_fn
end

-- Default-deny: launching a replay for a mod_id nothing registered a
-- launcher for is a debug-logged no-op, not a crash -- matches dispatch's
-- own default-deny philosophy above.
function MPAPI.playback.launch(mod_id, run_id)
	local fn = mod_id and MPAPI.playback._launchers[mod_id]
	if not fn then
		MPAPI.sendDebugMessage('MPAPI.playback: no launcher for ' .. tostring(mod_id) .. ' (ignored)')
		return
	end
	return fn(run_id)
end
