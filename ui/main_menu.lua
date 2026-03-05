-- Build a single mod button row with optional subtext
local function build_mod_button(mod, inner_width)
	local is_installed = mod.main_menu_ui ~= nil
	local subtext = not is_installed and localize('b_open_download_page') or nil
	local button_ref = { mod_id = mod.id }

	local button_nodes = {
		{ n = G.UIT.T, config = { text = mod.name, scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	}
	if subtext then
		button_nodes[#button_nodes + 1] = { n = G.UIT.T, config = { text = subtext, scale = 0.25, colour = mix_colours(G.C.UI.TEXT_LIGHT, G.C.UI.TEXT_DARK, 0.8) } }
	end

	local rows = {}
	for _, node in ipairs(button_nodes) do
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = { node } }
	end

	return {
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
					colour = (not is_installed and G.C.UI.BACKGROUND_INACTIVE) or mod.colour or G.C.PURPLE,
					button = 'mpapi_mod_button',
					ref_table = button_ref,
					ref_value = 'mod_id',
				},
				nodes = rows,
			},
		},
	}
end

local function create_UIBox_account_button()
	local status_colour = G.C.RED
	if MPAPI.connection_state.state == 'connected' then
		status_colour = G.C.WHITE
	elseif MPAPI.connection_state.state == 'authenticating' or MPAPI.connection_state.state == 'connecting' then
		status_colour = G.C.GOLD
	end

	local outer_width = 2.3
	local inner_width = 2.2

	local panel_nodes = {}

	-- Title
	panel_nodes[#panel_nodes + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_multiplayer'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }

	-- Account button
	panel_nodes[#panel_nodes + 1] = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.1, minw = inner_width, minh = 0.8, maxw = inner_width, r = 0.1, hover = true, colour = mix_colours(G.C.WHITE, G.C.GREY, 0.2), button = 'mpapi_account_button', shadow = true },
				nodes = {
					{ n = G.UIT.T, config = { ref_table = MPAPI.connection_state, ref_value = 'display_name', scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				},
			},
		},
	}

	if MPAPI.get_active_mod() then
		-- Mod active: show back button
		panel_nodes[#panel_nodes + 1] = {
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
	else
		-- Normal mode: show mod buttons vertically
		local mods = MPAPI.get_registered_mods()
		for _, mod in ipairs(mods) do
			panel_nodes[#panel_nodes + 1] = build_mod_button(mod, inner_width)
		end
	end

	-- Connection status
	panel_nodes[#panel_nodes + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
		{ n = G.UIT.T, config = { ref_table = MPAPI.connection_state, ref_value = 'status_text', scale = 0.3, colour = status_colour, shadow = true } },
	} }

	return {
		n = G.UIT.ROOT,
		config = { align = 'cm', minw = outer_width, maxw = outer_width, colour = G.C.CLEAR },
		nodes = {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1, r = 0.1, emboss = 0.1, colour = MPAPI.C.MP_EDITION, minw = outer_width, maxw = outer_width }, nodes = panel_nodes },
		},
	}
end

MPAPI.account_button = MPAPI.ui_element(create_UIBox_account_button)

-- Account button: open overlay when connected, retry when disconnected
G.FUNCS.mpapi_account_button = function(e)
	if MPAPI.connection_state.state == 'connected' then
		MPAPI.account_overlay:as_overlay()
	end
	if MPAPI.connection_state.state == 'disconnected' then
		MPAPI.disconnect()
		local last_opts = MPAPI.get_last_opts()
		MPAPI.connect(last_opts or {})
	end
end

-- Mod button: activate mod or open download page
G.FUNCS.mpapi_mod_button = function(e)
	local mod_id = e.config and e.config.ref_table and e.config.ref_table.mod_id
	if mod_id then
		MPAPI.activate_mod(mod_id)
	end
end

-- Back button: deactivate current mod, return to normal menu
G.FUNCS.mpapi_back_button = function(e)
	MPAPI.deactivate_mod()
end

-- Hook set_main_menu_UI: add account panel, handle active mod menu replacement
local _set_main_menu_UI_ref = set_main_menu_UI
MPAPI._capture_original_set_main_menu_UI(_set_main_menu_UI_ref)

function set_main_menu_UI()
	local active = MPAPI.get_active_mod()

	if active then
		-- Active mod: replace main menu with mod's UI
		local mods = MPAPI.get_registered_mods()
		local mod
		for _, m in ipairs(mods) do
			if m.id == active then
				mod = m
				break
			end
		end
		if mod and mod.main_menu_ui then
			if G.MAIN_MENU_UI then
				G.MAIN_MENU_UI:remove()
			end
			G.MAIN_MENU_UI = UIBox({
				definition = mod.main_menu_ui(),
				config = { align = 'bmi', offset = { x = 0, y = 10 }, major = G.ROOM_ATTACH, bond = 'Weak' },
			})
			G.MAIN_MENU_UI.alignment.offset.y = 0
			G.MAIN_MENU_UI:align_to_major()
		else
			_set_main_menu_UI_ref()
		end
	else
		_set_main_menu_UI_ref()
	end

	-- Always add account panel
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		func = function()
			MPAPI.account_button:as_uibox({ align = 'tli', offset = { x = -10, y = 0 }, major = G.ROOM_ATTACH, bond = 'Weak' }, function(uibox)
				uibox.alignment.offset.x = 0
				uibox:align_to_major()
			end)
			return true
		end,
	}))
end
