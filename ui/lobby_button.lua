-- The in-run HUD button next to Run Info (injected via this mod's own
-- lovely/hud.toml). It reads "Lobby Info" and opens the Lobby Info overlay.
-- While a Replay plays it becomes "Replay settings" and opens the speed
-- control (ui/replay_settings.lua). Other consumers can open the lobby overlay
-- with button = 'mpapi_show_lobby_info'.
G.FUNCS.mpapi_show_lobby_info = function()
	MPAPI.show_lobby_info_overlay()
end

local label = { top = '', bottom = '' }

-- The label table the button's two text nodes read (ref_table), kept current
-- so the text changes when a Replay starts or ends.
function MPAPI.lobby_button_label()
	local replay = MPAPI.playback.paced_driver() ~= nil
	label.top = localize(replay and 'b_replay_settings_1' or 'b_lobby_info_1')
	label.bottom = localize(replay and 'b_replay_settings_2' or 'b_lobby_info_2')
	return label
end

-- The button's per-frame `func`: picks what a click opens.
G.FUNCS.mpapi_lobby_button_mode = function(e)
	MPAPI.lobby_button_label()
	e.config.button = MPAPI.playback.paced_driver() and 'mpapi_show_replay_settings' or 'mpapi_show_lobby_info'
end
