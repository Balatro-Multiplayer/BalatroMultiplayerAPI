-- Forward declarations for helper functions
local build_mod_buttons
local build_mod_button
local attach_account_button

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_account_button = function()
	local status_colour = G.C.RED
	if MPAPI.connection_state.state == 'connected' then
		status_colour = G.C.WHITE
	elseif MPAPI.connection_state.state == 'authenticating' or MPAPI.connection_state.state == 'connecting' then
		status_colour = G.C.GOLD
	end

	local outer_width = 2.3
	local inner_width = 2.2

	local title_node = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_multiplayer'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }

	local is_busy = MPAPI.connection_state.state == 'connecting' or MPAPI.connection_state.state == 'authenticating'
	local account_button_config = {
		align = 'cm', padding = 0.1, minw = inner_width, minh = 0.8, maxw = inner_width, r = 0.1,
		colour = is_busy and G.C.UI.BACKGROUND_INACTIVE or mix_colours(G.C.WHITE, G.C.GREY, 0.2),
	}
	if not is_busy then
		account_button_config.hover = true
		account_button_config.button = 'mpapi_account_button'
		account_button_config.shadow = true
	end

	local state = MPAPI.connection_state.state
	local account_button_label
	if state == 'tos_required' and not MPAPI.connection_state.tos_is_update then
		account_button_label = { n = G.UIT.T, config = {
			text = localize('b_sign_up'),
			scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true,
		} }
	elseif state == 'tos_required' or state == 'login_available' then
		account_button_label = { n = G.UIT.T, config = {
			text = localize('b_sign_in'),
			scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true,
		} }
	else
		account_button_label = { n = G.UIT.T, config = {
			ref_table = MPAPI.connection_state, ref_value = 'display_name',
			scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true,
		} }
	end

	local account_button_node = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{
				n = G.UIT.C,
				config = account_button_config,
				nodes = { account_button_label },
			},
		},
	}

	local back_button_node = {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.03 },
		nodes = {
			{
				n = G.UIT.C,
				config = {
					align = 'cm',
					padding = 0.08,
					minw = inner_width,
					maxw = inner_width,
					minh = 0.6,
					r = 0.1,
					hover = true,
					shadow = true,
					colour = G.C.ORANGE,
					button = 'mpapi_back_button',
				},
				nodes = {
					{ n = G.UIT.R, config = { align = 'cm' }, nodes = {
						{ n = G.UIT.T, config = { text = localize('b_back'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					} },
				},
			},
		},
	}

	local connection_state = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
		{ n = G.UIT.T, config = { ref_table = MPAPI.connection_state, ref_value = 'status_text', scale = 0.3, colour = status_colour, shadow = true } },
	} }

	local account_button_nodes = {
		title_node,
		account_button_node,
	}

	if MPAPI.get_focused_mod() then
		-- A mod's menu is shown: offer a back button to return to the game menu.
		account_button_nodes[#account_button_nodes + 1] = back_button_node
	else
		-- On the game main menu: list all registered mods.
		-- If a lobby is active (_engaged_mod set), other mods are greyed out.
		local mods = MPAPI.get_registered_mods()
		local engaged = MPAPI.get_active_mod()
		for _, mod in ipairs(mods) do
			account_button_nodes[#account_button_nodes + 1] = build_mod_button(mod, inner_width, engaged)
		end
	end

	account_button_nodes[#account_button_nodes + 1] = connection_state

	return {
		n = G.UIT.ROOT,
		config = { align = 'cm', minw = outer_width, maxw = outer_width, colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.R,
				config = { align = 'cm', padding = 0.1, r = 0.1, emboss = 0.1, colour = MPAPI.C.MP_EDITION, minw = outer_width, maxw = outer_width },
				nodes = account_button_nodes,
			},
		},
	}
end

-- engaged_mod_id: the id of the mod that currently has an active lobby, or nil.
-- When set, every other mod button is disabled so the player cannot switch mods
-- mid-lobby. Clicking the engaged mod re-enters the lobby view.
build_mod_button = function(mod, inner_width, engaged_mod_id)
	local is_installed = mod.main_menu_ui ~= nil
	local is_engaged = engaged_mod_id ~= nil and mod.id == engaged_mod_id
	local is_blocked = engaged_mod_id ~= nil and not is_engaged
	local is_disconnected = MPAPI.connection_state.state ~= 'connected'
	local is_disabled = not is_installed or is_blocked or is_disconnected

	local subtext = not is_installed and not is_blocked and not is_disconnected and localize('b_open_download_page') or nil
	local button_ref = { mod_id = mod.id }

	local button_nodes = {
		{ n = G.UIT.T, config = { text = mod.name, scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	}
	if subtext then
		button_nodes[#button_nodes + 1] = {
			n = G.UIT.T,
			config = { text = subtext, scale = 0.25, colour = mix_colours(G.C.UI.TEXT_LIGHT, G.C.UI.TEXT_DARK, 0.8) },
		}
	end

	local rows = {}
	for _, node in ipairs(button_nodes) do
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = { node } }
	end

	local colour = (is_disabled and G.C.UI.BACKGROUND_INACTIVE) or (is_engaged and mix_colours(mod.colour or G.C.PURPLE, G.C.WHITE, 0.3)) or mod.colour or G.C.PURPLE

	local config = {
		align = 'cm',
		padding = 0.08,
		minw = inner_width,
		maxw = inner_width,
		minh = 0.6,
		r = 0.1,
		shadow = true,
		colour = colour,
	}

	if not is_disabled then
		config.hover = true
		config.button = 'mpapi_mod_button'
		config.ref_table = button_ref
		config.ref_value = 'mod_id'
	end

	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.03 },
		nodes = {
			{ n = G.UIT.C, config = config, nodes = rows },
		},
	}
end

attach_account_button = function()
	MPAPI.sendDebugMessage('[main_menu] attach_account_button queued | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		func = function()
			MPAPI.sendDebugMessage('[main_menu] as_uibox firing | UIBOX before: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
			MPAPI.account_button:as_uibox({ align = 'tli', offset = { x = -10, y = 0 }, major = G.ROOM_ATTACH, bond = 'Weak' }, function(uibox)
				uibox.alignment.offset.x = 0
				uibox:align_to_major()
			end)
			MPAPI.sendDebugMessage('[main_menu] as_uibox done | UIBOX after: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
			return true
		end,
	}))
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_account_button = function(e)
	local state = MPAPI.connection_state.state
	if state == 'connected' then
		MPAPI.account_overlay:as_overlay()
	elseif state == 'disconnected' then
		MPAPI.sendDebugMessage('[main_menu] retry pressed | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?') .. ' | ROOM_ATTACH scale: ' .. tostring(G.ROOM_ATTACH and G.ROOM_ATTACH.VT and G.ROOM_ATTACH.VT.scale or '?'))
		MPAPI.disconnect()
		local last_opts = MPAPI.shallow_copy(MPAPI.get_last_opts() or {})
		last_opts.force_login = true
		MPAPI.connect(last_opts)
	elseif state == 'tos_required' then
		if MPAPI._internal.show_tos_overlay then
			MPAPI._internal.show_tos_overlay(MPAPI.connection_state.tos_is_update)
		end
	elseif state == 'login_available' then
		local conn = MPAPI.get_connection()
		if conn then
			conn:login()
		end
	end
end

G.FUNCS.mpapi_mod_button = function(e)
	local mod_id = e.config and e.config.ref_table and e.config.ref_table.mod_id
	if mod_id then
		MPAPI._internal.activate_mod(mod_id)
	end
end

G.FUNCS.mpapi_back_button = function(e)
	MPAPI._internal.deactivate_mod()
end

-----------------------------
-- GLOBAL UI ELEMENTS
-----------------------------

MPAPI.account_button = MPAPI.ui_element(create_UIBox_account_button)

-----------------------------
-- OVERRIDES
-----------------------------

local _set_main_menu_UI_call_count = 0
local _set_main_menu_UI_ref = set_main_menu_UI
set_main_menu_UI = function()
	_set_main_menu_UI_call_count = _set_main_menu_UI_call_count + 1
	MPAPI.sendDebugMessage('[main_menu] set_main_menu_UI #' .. _set_main_menu_UI_call_count .. ' | UIBOX: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
	if not MPAPI._internal.rebuild_current_menu() then
		_set_main_menu_UI_ref()
	end

	attach_account_button()
end
