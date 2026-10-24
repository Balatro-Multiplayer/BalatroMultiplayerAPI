-- "Replay settings": the speed control of a Replay (1x, 2x, 4x, fast-forward),
-- opened from the in-run HUD button (ui/lobby_button.lua). Works on the running
-- paced playback driver (api/playback/driver.lua), so every mod's Replay shares it.
local Speed = MPAPI.playback.Speed

local SPEED_OPTIONS = {
	{ speed = Speed.X1, label = '1x' },
	{ speed = Speed.X2, label = '2x' },
	{ speed = Speed.X4, label = '4x' },
	{ speed = Speed.FAST_FORWARD, label = '>>' },
}

local function speed_button(option, selected)
	return {
		n = G.UIT.C,
		config = {
			align = 'cm',
			padding = 0.08,
			minw = 1.2,
			minh = 0.7,
			r = 0.1,
			hover = true,
			shadow = true,
			colour = selected and G.C.BLUE or G.C.GREY,
			button = 'mpapi_replay_set_speed',
			ref_table = { speed = option.speed },
		},
		nodes = {
			{ n = G.UIT.T, config = { text = option.label, scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		},
	}
end

local function create_UIBox_replay_settings()
	local driver = MPAPI.playback.paced_driver()
	local current = driver and driver:get_speed()
	local buttons = {}
	for _, option in ipairs(SPEED_OPTIONS) do
		buttons[#buttons + 1] = speed_button(option, option.speed == current)
	end
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 6, padding = 0.2, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_replay_speed'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{ n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = buttons },
			},
		},
	}
	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

MPAPI.replay_settings_overlay = MPAPI.ui_element(create_UIBox_replay_settings)

G.FUNCS.mpapi_show_replay_settings = function()
	if MPAPI.playback.paced_driver() then
		MPAPI.replay_settings_overlay:as_overlay()
	end
end

-- Picking a speed reopens the overlay so the selected button shows.
G.FUNCS.mpapi_replay_set_speed = function(e)
	local driver = MPAPI.playback.paced_driver()
	if not driver then
		return
	end
	driver:set_speed(e.config.ref_table.speed)
	G.FUNCS.exit_overlay_menu()
	MPAPI.replay_settings_overlay:as_overlay()
end
