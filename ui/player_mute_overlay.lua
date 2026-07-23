-- Mute/unmute overlay for a single lobby player, opened from a lobby card click
-- (ui/lobby.lua's lobby_card_click_override). A click-triggered overlay rather
-- than living in the card's hover popup, since h_popups are a passive hover
-- display not reliably interactive.
local _target_id = nil
local _target_name = nil
local _submitting = false

local create_UIBox_player_mute_overlay = function()
	local muted = _target_id ~= nil and MPAPI.connection_state.mute_list[_target_id] or false

	local submit_colour = _submitting and G.C.UI.BACKGROUND_INACTIVE
		or (muted and G.C.GREEN or G.C.RED)
	local submit_text_colour = _submitting and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT
	local submit_config = {
		align = 'cm', padding = 0.15, minw = 5, minh = 0.7,
		r = 0.1, colour = submit_colour, shadow = true,
	}
	if not _submitting then
		submit_config.hover = true
		submit_config.button = 'mpapi_toggle_mute'
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = _target_name or '', scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = submit_config, nodes = {
							{ n = G.UIT.T, config = {
								text = localize(muted and 'k_unmute_player' or 'k_mute_player'),
								scale = 0.45, colour = submit_text_colour, shadow = true,
							} },
						} },
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_toggle_mute = function(e)
	if _submitting or not _target_id then
		return
	end
	_submitting = true
	if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end

	local already_muted = MPAPI.connection_state.mute_list[_target_id]
	local action = already_muted and MPAPI._internal.unmute_player or MPAPI._internal.mute_player

	action(_target_id, function(err)
		_submitting = false
		if err then
			MPAPI.sendWarnMessage('[mute] Toggle mute failed: ' .. tostring(err))
			if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
			return
		end
		if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
	end)
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.player_mute_overlay = MPAPI.ui_element(create_UIBox_player_mute_overlay)

-- Called from ui/lobby.lua's lobby_card_click_override with the clicked
-- player's id/display name.
function MPAPI.open_player_mute_overlay(player_id, player_name)
	_target_id = player_id
	_target_name = player_name or 'Unknown'
	_submitting = false
	MPAPI.player_mute_overlay:as_overlay()
end
