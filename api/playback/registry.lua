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

MPAPI.playback._rejoin_launchers = MPAPI.playback._rejoin_launchers or {}

-- Registers a mod's own "rejoin this in-progress match after a crash/relaunch"
-- entry point -- keyed the same way register_launcher is (by the mod_id a
-- RunRow's own `modId` carries). A rejoin launcher reuses the SAME
-- fast-forward-through-own-RLOG mechanism a replay launcher does (they're
-- expected to share the bootstrap/driver plumbing), but ends by handing off
-- to LIVE play (rejoining the real lobby) instead of showing a "replay
-- finished" summary screen -- a distinct entry point from register_launcher
-- because the ending is fundamentally different, not because the beginning
-- is. See ui/rejoin_prompt.lua for the caller (the boot-time Rejoin/Abandon
-- prompt).
function MPAPI.playback.register_rejoin(mod_id, rejoin_fn)
	MPAPI.playback._rejoin_launchers[mod_id] = rejoin_fn
end

-- fn(active) where active = {runId, lobbyCode, modId, events}, exactly
-- MPAPI.replay.get_active_run's own response shape -- `events` is the
-- rejoining player's OWN buffered event stream (server-side: getTail against
-- the LIVE in-memory run buffer, not a DB-persisted replay -- an active run
-- has no matchRunLogs row yet, so MPAPI.replay.get(run_id) 403s "not a
-- participant" for a genuinely active run's own participant; confirmed live).
-- Passed through whole rather than destructured, since a rejoin launcher
-- needs every field: lobbyCode to MPAPI.join_lobby back into once the local
-- fast-forward completes, events to actually fast-forward with.
function MPAPI.playback.rejoin(mod_id, active)
	local fn = mod_id and MPAPI.playback._rejoin_launchers[mod_id]
	if not fn then
		MPAPI.sendDebugMessage('MPAPI.playback: no rejoin launcher for ' .. tostring(mod_id) .. ' (ignored)')
		return
	end
	return fn(active)
end
