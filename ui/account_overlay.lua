local function account_info_row(label, value_nodes)
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

-- This function is heavily inspired by Galdur's Galdur.display_deck_preview()
-- Check out Galdur at https://github.com/Eremel/Galdur (version 1.2.1d)
local function joker_preview()
	local joker_id = MPAPI.connection_state.preferred_joker or 'j_joker'
	local center = G.P_CENTERS[joker_id] or G.P_CENTERS['j_joker']
	local card = Card(0, 0, G.CARD_W, G.CARD_H, G.P_CARDS.empty, center, { mpapi_avatar_preview = true })
	card.states.drag.can = false
	card.states.hover.can = true
	card.states.click.can = true

	local card_node = { n = G.UIT.R, config = { align = 'tm' }, nodes = {
		{ n = G.UIT.O, config = { object = card } },
	} }

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
					card_node,
					{ n = G.UIT.R, config = { minh = 0.8, align = 'bm' }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_click_to_change'), scale = 0.6, colour = G.C.GREY } },
					} },
				},
			},
		},
	}
end

local function create_UIBox_account_overlay()
	if MPAPI.connection_state.state ~= 'connected' then
		return G.FUNCS.exit_overlay_menu()
	end

	-- Username
	local player_name = MPAPI.connection_state.steam_name ~= '' and MPAPI.connection_state.steam_name or 'Unknown'
	local name_colour = G.C.GREEN
	if MPAPI.connection_state.is_temp then
		player_name = player_name .. ' (Dev)'
		name_colour = G.C.GOLD
	end

	-- Discord
	local discord_linked = MPAPI.connection_state.discord_name ~= ''
	local discord_value = discord_linked and MPAPI.connection_state.discord_name or 'Not Linked'
	local discord_colour = discord_linked and G.C.GREEN or G.C.UI.TEXT_INACTIVE

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 3, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				-- Title
				{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
					{ n = G.UIT.T, config = { text = 'Multiplayer Account', scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				} },
				-- Body: joker card + info
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						joker_preview(),
						-- Info + settings column
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.05 },
							nodes = {
								-- Info rows
								{
									n = G.UIT.R,
									config = { align = 'cm', padding = 0.1 },
									nodes = {
										account_info_row('ID', {
											{ n = G.UIT.T, config = { text = MPAPI.connection_state.player_id, scale = 0.3, colour = G.C.UI.TEXT_INACTIVE } },
										}),
										account_info_row('Steam Username', {
											{ n = G.UIT.O, config = { object = DynaText({ string = { player_name }, colours = { name_colour }, shadow = true, float = true, scale = 0.45 }) } },
										}),
										account_info_row('Discord Username', {
											{ n = G.UIT.O, config = { object = DynaText({ string = { discord_value }, colours = { discord_colour }, shadow = true, float = true, scale = 0.45 }) } },
										}),
									},
								},
								-- Settings row
								{
									n = G.UIT.R,
									config = { align = 'cm', padding = 0.1 },
									nodes = {
										{
											n = G.UIT.C,
											config = { align = 'cm', padding = 0.1 },
											nodes = {
												MPAPI.disableable_option_cycle({
													label = 'Display Name',
													options = { 'Steam', 'Discord' },
													current_option = MPAPI.connection_state.use_discord_name and 2 or 1,
													opt_callback = 'mpapi_change_use_discord_name',
													scale = 0.8,
													colour = MPAPI.C.MP_EDITION,
													focus_args = { nav = 'wide' },
													enabled = discord_linked,
												}).node,
											},
										},
										{
											n = G.UIT.C,
											config = { align = 'cm', padding = 0.1 },
											nodes = {
												discord_linked and UIBox_button({ label = { 'Unlink Discord' }, button = 'mpapi_unlink_discord', minh = 0.7, scale = 0.4, colour = G.C.RED, focus_args = { nav = 'wide' } })
													or UIBox_button({ label = { 'Link Discord' }, button = 'mpapi_link_discord', minh = 0.7, scale = 0.4, colour = G.C.BLUE, focus_args = { nav = 'wide' } }),
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ back_func = 'exit_overlay_menu', snap_back = true, contents = contents })
end

MPAPI.account_overlay = MPAPI.ui_element(create_UIBox_account_overlay)

G.FUNCS.mpapi_change_use_discord_name = function(args)
	local use_discord = args.to_key == 2
	MPAPI.set_use_discord_name(use_discord, function(err, data)
		if err then
			MPAPI.sendWarnMessage('Failed to set display name preference: ' .. tostring(err))
			return
		end
		MPAPI.sendDebugMessage('Display name preference updated')
	end)
end

G.FUNCS.mpapi_unlink_discord = function(e)
	MPAPI.unlink_discord(function(err, data)
		if err then
			MPAPI.sendWarnMessage('Discord unlink error: ' .. tostring(err))
			return
		end
		MPAPI.sendDebugMessage('Discord unlinked successfully')
	end)
end

G.FUNCS.mpapi_link_discord = function(e)
	MPAPI.get_discord_link_url(function(err, data)
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
