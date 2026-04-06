-- Forward declarations for helper functions
local multiplayer_account_title
local joker_preview
local account_info_row
local account_info_rows
local display_name_option_cycle
local auto_login_toggle
local discord_linking_buttons
local settings_row
local chat_section

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_account_overlay = function()
	if MPAPI.connection_state.state ~= 'connected' then
		return G.FUNCS.exit_overlay_menu()
	end

	local steam_name = MPAPI.connection_state.steam_name ~= '' and MPAPI.connection_state.steam_name or localize('k_unknown')
	local name_colour = G.C.GREEN
	if MPAPI.connection_state.is_temp then
		steam_name = steam_name .. ' ' .. localize('k_dev_mode_suffix')
		name_colour = G.C.GOLD
	end

	local discord_linked = MPAPI.connection_state.discord_name ~= ''

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 3, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				multiplayer_account_title(),
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						joker_preview(),
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.05 },
							nodes = {
								account_info_rows(steam_name, name_colour, discord_linked),
								settings_row(discord_linked),
								chat_section(),
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

multiplayer_account_title = function()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_multiplayer_account'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }
end

-- This function is heavily inspired by Galdur's Galdur.display_deck_preview()
-- Check out Galdur at https://github.com/Eremel/Galdur (version 1.2.1d)
joker_preview = function()
	local card = MPAPI.create_account_avatar({ mpapi_avatar_preview = true })

	return {
		n = G.UIT.C,
		config = { align = 'tm', padding = 0.15 },
		nodes = {
			{
				n = G.UIT.R,
				config = { minh = 5.95, minw = 3, maxw = 3, colour = G.C.BLACK, r = 0.1, align = 'bm', padding = 0.15, emboss = 0.05 },
				nodes = {
					{
						n = G.UIT.R,
						config = { align = 'cm', minh = 0.6, maxw = 2.8 },
						nodes = {
							{
								n = G.UIT.O,
								config = {
									id = 'your_avatar_1',
									object = DynaText({
										string = { localize('k_your_avatar_cap_1') },
										scale = 0.75,
										colours = { G.C.GREY },
										pop_in_rate = 5,
										silent = true,
									}),
								},
							},
						},
					},
					{
						n = G.UIT.R,
						config = { align = 'cm', minh = 0.6, maxw = 2.8 },
						nodes = {
							{
								n = G.UIT.O,
								config = {
									id = 'your_avatar_2',
									object = DynaText({
										string = { localize('k_your_avatar_cap_2') },
										scale = 0.75,
										colours = { G.C.GREY },
										pop_in_rate = 5,
										silent = true,
									}),
								},
							},
						},
					},
					{ n = G.UIT.R, config = { align = 'cm', minh = 0.2 } },
					{ n = G.UIT.R, config = { align = 'tm' }, nodes = { { n = G.UIT.O, config = { object = card } } } },
					{ n = G.UIT.R, config = { minh = 0.8, align = 'bm' }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_click_to_change'), scale = 0.6, colour = G.C.GREY } },
					} },
				},
			},
		},
	}
end

account_info_row = function(label, value_nodes)
	local label_w, value_w = 3.5, 4.5
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.05, r = 0.1, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.05 },
		nodes = {
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.05, minw = label_w, maxw = label_w }, nodes = {
				{ n = G.UIT.T, config = { text = label, scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
			{
				n = G.UIT.C,
				config = { align = 'cl', minh = 0.7, r = 0.1, minw = value_w, colour = G.C.BLACK, emboss = 0.05 },
				nodes = {
					{ n = G.UIT.C, config = { align = 'cm', padding = 0.05, r = 0.1, minw = value_w, maxw = value_w }, nodes = value_nodes },
				},
			},
		},
	}
end

account_info_rows = function(steam_name, name_colour, discord_linked)
	local discord_value = discord_linked and MPAPI.connection_state.discord_name or localize('k_not_linked')
	local discord_colour = discord_linked and G.C.GREEN or G.C.UI.TEXT_INACTIVE

	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			account_info_row(localize('k_id'), {
				{ n = G.UIT.T, config = { text = MPAPI.connection_state.player_id, scale = 0.3, colour = G.C.UI.TEXT_INACTIVE } },
			}),
			account_info_row(localize('k_steam_username'), {
				{ n = G.UIT.O, config = { object = DynaText({ string = { steam_name }, colours = { name_colour }, shadow = true, float = true, scale = 0.45 }) } },
			}),
			account_info_row(localize('k_discord_username'), {
				{ n = G.UIT.O, config = { object = DynaText({ string = { discord_value }, colours = { discord_colour }, shadow = true, float = true, scale = 0.45 }) } },
			}),
		},
	}
end

display_name_option_cycle = function(discord_linked)
	return {
		n = G.UIT.C,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			MPAPI.disableable_option_cycle({
				label = localize('k_display_name'),
				options = { localize('k_steam'), localize('k_discord') },
				current_option = MPAPI.connection_state.use_discord_name and 2 or 1,
				opt_callback = 'mpapi_change_use_discord_name',
				scale = 0.8,
				colour = MPAPI.C.MP_EDITION,
				focus_args = { nav = 'wide' },
				enabled = discord_linked,
			}).node,
		},
	}
end

auto_login_toggle = function()
	return {
		n = G.UIT.C,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			MPAPI.disableable_toggle({
				label = localize('k_auto_login'),
				ref_table = MPAPI.connection_state,
				ref_value = 'auto_login',
				callback = G.FUNCS.mpapi_change_auto_login,
				enabled = true,
			}).node,
		},
	}
end

discord_linking_buttons = function(discord_linked)
	local button = UIBox_button({ label = { localize('k_link_discord') }, button = 'mpapi_link_discord', minh = 0.7, scale = 0.4, colour = G.C.BLUE, focus_args = { nav = 'wide' } })

	if discord_linked then
		button = UIBox_button({ label = { localize('k_unlink_discord') }, button = 'mpapi_unlink_discord', minh = 0.7, scale = 0.4, colour = G.C.RED, focus_args = { nav = 'wide' } })
	end

	return {
		n = G.UIT.C,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			button,
		},
	}
end

settings_row = function(discord_linked)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			display_name_option_cycle(discord_linked),
			auto_login_toggle(),
			discord_linking_buttons(discord_linked),
		},
	}
end

chat_section = function()
	local server_enabled = MPAPI.connection_state.chat_enabled
	local chat_blocked   = MPAPI.connection_state.chat_blocked

	local nodes = {
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.06 },
			nodes = {
				{ n = G.UIT.T, config = {
					text = localize('k_chat_section_title'),
					scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true,
				} },
			},
		},
	}

	if chat_blocked then
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.04 },
			nodes = {
				{ n = G.UIT.T, config = {
					text = localize('k_chat_status_blocked'),
					scale = 0.35, colour = G.C.RED,
				} },
			},
		}
	elseif server_enabled then
		-- Client-side enable/disable toggle (no re-verification needed)
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.04 },
			nodes = {
				MPAPI.disableable_toggle({
					label = localize('k_chat_section_title'),
					ref_table = MPAPI.config,
					ref_value = 'chat_enabled',
					callback = G.FUNCS.mpapi_chat_toggle,
					enabled = true,
				}).node,
			},
		}
	else
		-- Not verified yet: show status + button
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.04 },
			nodes = {
				{ n = G.UIT.T, config = {
					text = localize('k_chat_status_none'),
					scale = 0.35, colour = G.C.UI.TEXT_INACTIVE,
				} },
			},
		}
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.08 },
			nodes = {
				{
					n = G.UIT.C,
					config = {
						align = 'cm', padding = 0.1, minw = 5, minh = 0.7,
						r = 0.1, hover = true, colour = G.C.GREEN,
						button = 'mpapi_open_chat_enable', shadow = true,
					},
					nodes = {
						{ n = G.UIT.T, config = {
							text = localize('b_chat_enable'),
							scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true,
						} },
					},
				},
			},
		}
	end

	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.05, r = 0.1, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.05 },
				nodes = nodes,
			},
		},
	}
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_change_use_discord_name = function(args)
	local use_discord = args.to_key == 2
	MPAPI._internal.set_use_discord_name(use_discord, function(err, data)
		if err then
			MPAPI.sendWarnMessage('Failed to set display name preference: ' .. tostring(err))
			return
		end
		MPAPI.sendDebugMessage('Display name preference updated')
	end)
end

G.FUNCS.mpapi_change_auto_login = function(new_value)
	local conn = MPAPI.get_connection()
	if conn then
		if new_value then
			conn:enable_auto_login()
		else
			conn:disable_auto_login()
		end
	end
end

G.FUNCS.mpapi_unlink_discord = function(e)
	MPAPI._internal.unlink_discord(function(err, data)
		if err then
			MPAPI.sendWarnMessage('Discord unlink error: ' .. tostring(err))
			return
		end
		MPAPI.sendDebugMessage('Discord unlinked successfully')
	end)
end

G.FUNCS.mpapi_chat_toggle = function(new_value)
	MPAPI._internal.config_set('chat_enabled', new_value)
	MPAPI.chat.on_config_changed(new_value)
end

G.FUNCS.mpapi_link_discord = function(e)
	MPAPI._internal.get_discord_link_url(function(err, data)
		if err then
			MPAPI.sendWarnMessage('Discord link error: ' .. tostring(err))
			return
		end
		if data and data.url then
			MPAPI.sendDebugMessage('Opening Discord link URL')
			love.system.openURL(data.url)
		end
	end)
end

-----------------------------
-- GLOBAL UI ELEMENTS
-----------------------------

MPAPI.account_overlay = MPAPI.ui_element(create_UIBox_account_overlay)
