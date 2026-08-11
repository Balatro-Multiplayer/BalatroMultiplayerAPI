-- Per-mod extension point for the lobby-card grid (ui/lobby_card_grid.lua):
-- each mod registers one callback (mod-wide, mirrors
-- api/card_info_providers.lua's shape and scoping) that says whether a given
-- player should render debuffed in the roster -- dead/eliminated, forfeited,
-- or otherwise not part of the current run. MPAPI core has no concept of
-- "alive"/"forfeited" itself (that's entirely mod/gamemode-defined), so this
-- is the hook mods use to answer it.
MPAPI._player_status_providers = {}

function MPAPI.register_player_status_provider(mod_id, fn)
	MPAPI._player_status_providers[mod_id] = fn
end

-- Returns true if `player_data` should render debuffed in `lobby`'s card
-- grid. Scoped to lobby.mod_id only (same reasoning as
-- MPAPI._build_card_info_rows: a player with multiple MPAPI mods installed
-- must not see one mod's status logic bleed into another mod's lobby). A
-- provider that errors is treated as "not debuffed" rather than crashing the
-- grid.
function MPAPI._is_player_debuffed(lobby, player_data)
	local fn = lobby and lobby.mod_id and MPAPI._player_status_providers[lobby.mod_id]
	if not fn then
		return false
	end
	local ok, result = pcall(fn, lobby, player_data)
	return ok and result == true
end
