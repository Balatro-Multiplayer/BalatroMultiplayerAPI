-- Module-level state
local _tos_accept_ready = false
local _is_update = false
local _pending_show = false

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_tos_overlay = function()
	local subtitle_lines = _is_update
		and { localize('k_tos_update_1'), localize('k_tos_update_2') }
		or { localize('k_tos_first_time_1'), localize('k_tos_first_time_2'), localize('k_tos_first_time_3') }

	local accept_colour = _tos_accept_ready and G.C.GREEN or G.C.UI.BACKGROUND_INACTIVE
	local accept_text_colour = _tos_accept_ready and G.C.UI.TEXT_LIGHT or G.C.UI.TEXT_INACTIVE

	local accept_config = {
		align = 'cm',
		padding = 0.1,
		minw = 3.5,
		minh = 0.7,
		r = 0.1,
		colour = accept_colour,
		shadow = true,
	}
	if _tos_accept_ready then
		accept_config.hover = true
		accept_config.button = 'mpapi_tos_accept'
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				-- Title
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_tos_title'), scale = 0.6, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				-- Subtitle
				(function()
					local rows = {}
					for _, line in ipairs(subtitle_lines) do
						rows[#rows + 1] = {
							n = G.UIT.R,
							config = { align = 'cm', padding = 0.05 },
							nodes = {
								{ n = G.UIT.T, config = { text = line, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
							},
						}
					end
					return { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
						{ n = G.UIT.C, config = { align = 'cm' }, nodes = rows }
					} }
				end)(),
				-- Spacer
				{ n = G.UIT.R, config = { minh = 0.1 } },
				-- View ToS button
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.08 },
					nodes = {
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.1, minw = 5, minh = 0.7, r = 0.1, hover = true, colour = G.C.BLUE, button = 'mpapi_view_tos', shadow = true },
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_view_tos'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
							},
						},
					},
				},
				-- View Privacy Policy button
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.08 },
					nodes = {
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.1, minw = 5, minh = 0.7, r = 0.1, hover = true, colour = G.C.BLUE, button = 'mpapi_view_privacy', shadow = true },
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_view_privacy'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
							},
						},
					},
				},
				-- Spacer
				{ n = G.UIT.R, config = { minh = 0.15 } },
				-- Accept / Decline buttons
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						-- I Accept
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.1 },
							nodes = {
								{
									n = G.UIT.C,
									config = accept_config,
									nodes = {
										{ n = G.UIT.T, config = { text = localize('b_i_accept'), scale = 0.45, colour = accept_text_colour, shadow = true } },
									},
								},
							},
						},
						-- I Decline
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.1 },
							nodes = {
								{
									n = G.UIT.C,
									config = { align = 'cm', padding = 0.1, minw = 3.5, minh = 0.7, r = 0.1, hover = true, colour = G.C.RED, button = 'mpapi_tos_decline', shadow = true },
									nodes = {
										{ n = G.UIT.T, config = { text = localize('b_i_decline'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
									},
								},
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = false, contents = contents })
end

-----------------------------
-- INTERNAL API
-----------------------------

local function _do_show()
	_pending_show = false
	MPAPI.sendDebugMessage('[tos] _do_show | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?') .. ' | ROOM_ATTACH scale: ' .. tostring(G.ROOM_ATTACH and G.ROOM_ATTACH.VT and G.ROOM_ATTACH.VT.scale or '?'))
	MPAPI.tos_overlay:as_overlay()
	MPAPI.sendDebugMessage('[tos] overlay opened | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		trigger = 'after',
		delay = 2.0,
		func = function()
			_tos_accept_ready = true
			if MPAPI.tos_overlay then
				MPAPI.tos_overlay:update()
			end
			return true
		end,
	}))
end

-- Called when the connection enters tos_required state.
-- If the main menu is already active, shows immediately.
-- Otherwise sets a pending flag for flush_tos_overlay to pick up.
MPAPI._internal.show_tos_overlay = function(is_update)
	_is_update = is_update or false
	_tos_accept_ready = false

	if G.STATE == G.STATES.MENU then
		_do_show()
	else
		_pending_show = true
	end
end

-- Called from set_main_menu_UI after the menu is fully built.
-- Flushes any pending ToS overlay request.
MPAPI._internal.flush_tos_overlay = function()
	if _pending_show then
		_do_show()
	end
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_tos_accept = function(e)
	if not _tos_accept_ready then return end
	G.FUNCS.exit_overlay_menu()
	local conn = MPAPI.get_connection()
	if conn then
		conn:accept_tos()
	end
end

G.FUNCS.mpapi_tos_decline = function(e)
	MPAPI.sendDebugMessage('[tos] decline | UIBOX before: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?') .. ' | ROOM_ATTACH scale: ' .. tostring(G.ROOM_ATTACH and G.ROOM_ATTACH.VT and G.ROOM_ATTACH.VT.scale or '?'))
	G.FUNCS.exit_overlay_menu()
	MPAPI.sendDebugMessage('[tos] after exit_overlay | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
	local conn = MPAPI.get_connection()
	if conn then
		conn:decline_tos()
	end
end

G.FUNCS.mpapi_view_tos = function(e)
	love.system.openURL('https://api.balatromp.com/tos')
end

G.FUNCS.mpapi_view_privacy = function(e)
	love.system.openURL('https://api.balatromp.com/privacy')
end

-----------------------------
-- GLOBAL UI ELEMENTS
-----------------------------

MPAPI.tos_overlay = MPAPI.ui_element(create_UIBox_tos_overlay)
