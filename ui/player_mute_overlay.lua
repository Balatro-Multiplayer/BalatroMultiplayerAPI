-- Mute/unmute overlay for a single lobby player, opened from a lobby card click
-- (ui/lobby.lua's lobby_card_click_override). A click-triggered overlay rather
-- than living in the card's hover popup, since h_popups are a passive hover
-- display not reliably interactive.
local _target_id = nil
local _target_name = nil
local _submitting = false

local create_UIBox_player_mute_overlay = function()
	local muted = _target_id ~= nil and MPAPI.connection_state.mute_list[_target_id] or false

	-- Redundant with ui/lobby.lua's lobby_card_click_override already excluding
	-- self-clicks, but kept here so this overlay's gating is self-contained and
	-- robust to any future caller of open_player_mute_overlay.
	local lobby = MPAPI.get_current_lobby()
	local can_kick = lobby and lobby.is_host and _target_id ~= lobby.player_id

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

	local rows = {
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
		{ n = G.UIT.R, config = { minh = 0.15 } },
		{
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				{ n = G.UIT.C, config = {
					align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
					colour = G.C.ORANGE, shadow = true, hover = true, button = 'mpapi_open_report_player',
				}, nodes = {
					{ n = G.UIT.T, config = {
						text = localize('k_report_player'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true,
					} },
				} },
			},
		},
	}

	if can_kick then
		local kick_colour = _submitting and G.C.UI.BACKGROUND_INACTIVE or G.C.RED
		local kick_config = {
			align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
			colour = kick_colour, shadow = true,
		}
		if not _submitting then
			kick_config.hover = true
			kick_config.button = 'mpapi_kick_player'
		end

		rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.15 } }
		rows[#rows + 1] = {
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				{ n = G.UIT.C, config = kick_config, nodes = {
					{ n = G.UIT.T, config = {
						text = localize('k_kick_player'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true,
					} },
				} },
			},
		}
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = rows,
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_open_report_player = function(e)
	MPAPI.open_player_report_overlay(_target_id, _target_name)
end

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

G.FUNCS.mpapi_kick_player = function(e)
	if _submitting or not _target_id then
		return
	end
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		return
	end
	_submitting = true
	if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end

	MPAPI._internal.kick_player(lobby.code, _target_id, function(err)
		_submitting = false
		if err then
			MPAPI.sendWarnMessage('[kick] Kick failed: ' .. tostring(err))
			if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
			return
		end
		-- Target is gone; nothing left to show in this overlay.
		G.FUNCS.exit_overlay_menu()
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
