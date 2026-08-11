-- Per-mod "I just got my lobby object back after a reconnect, now show the
-- right UI for whatever state it's in" registry -- same idiom as
-- MPAPI.playback.register_rejoin/register_launcher (api/playback/registry.lua):
-- MPAPI itself has no idea how to build SPDRN's or PvP's own lobby screen
-- (player-card grid, ready buttons, deck picker, ...) or how to resume a
-- mid-draft ban-pick overlay for that mod's own gamemode config, only the
-- mod that owns that UI does. Called by ui/reconnect_prompt.lua once the
-- lobby object itself has been recreated (MPAPI._internal.create_reconnected_lobby)
-- and there's no active RLOG run to hand off to instead (see that file for
-- the full decision tree).
MPAPI._lobby_reconnect_handlers = MPAPI._lobby_reconnect_handlers or {}

function MPAPI.register_lobby_reconnect(mod_id, fn)
	MPAPI._lobby_reconnect_handlers[mod_id] = fn
end

-- Default-deny: a mod that never registered a lobby-reconnect handler is a
-- debug-logged no-op, not a crash -- matches MPAPI.playback.dispatch/launch's
-- own default-deny philosophy. The player still ends up with a live lobby
-- object either way; they just won't see a rebuilt lobby screen until they
-- navigate to it manually.
function MPAPI.lobby_reconnect(mod_id, lobby)
	local fn = mod_id and MPAPI._lobby_reconnect_handlers[mod_id]
	if not fn then
		MPAPI.sendDebugMessage('MPAPI: no lobby_reconnect handler for ' .. tostring(mod_id) .. ' (ignored)')
		return
	end
	return fn(lobby)
end
