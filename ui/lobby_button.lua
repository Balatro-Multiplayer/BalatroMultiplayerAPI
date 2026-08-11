-- The "Lobby Info" click handler, shared by every MPAPI-based mod's in-run
-- HUD button (injected via this mod's own lovely/hud.toml -- see git history
-- for the per-mod patches this replaced) and any other consumer that wants
-- to open the same overlay via button = 'mpapi_show_lobby_info'.
G.FUNCS.mpapi_show_lobby_info = function()
	MPAPI.show_lobby_info_overlay()
end
