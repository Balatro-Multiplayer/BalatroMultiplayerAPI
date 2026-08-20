-- Forward declarations for helper functions
local multiplayer_account_title
local joker_preview
local account_info_row
local account_info_rows
local display_name_option_cycle
local discord_linking_buttons
local settings_row
local chat_section
local respectful_use_block
local build_account_tab_content
local build_chat_tab_content
local format_run_date
local match_status_label_and_colour
local match_history_row
local build_history_tab_content
local fetch_history_page
local build_account_overlay_inner
local account_overlay_inner

-----------------------------
-- STATE
-----------------------------

-- tab: which of the three tabs is currently shown. history: the Match
-- History tab's own paginated fetch state, reset whenever the overlay is
-- freshly opened (MPAPI.open_account_overlay below) but preserved across
-- in-place :update() refreshes triggered by unrelated events (chat-enable
-- completion, connection-state changes -- see those call sites' own comments
-- further down).
local _state = {
	tab = 'account', -- 'account' | 'chat' | 'history'
	history = {
		page = 1,
		page_size = 10,
		loading = false,
		error = nil,
		runs = {},
		total = 0,
	},
}

local TABS = {
	{ key = 'account', label_key = 'k_account_tab_account' },
	{ key = 'chat', label_key = 'k_account_tab_chat' },
	-- { key = 'history', label_key = 'k_account_tab_history' },
}

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_account_overlay = function()
	if MPAPI.connection_state.state ~= MPAPI.ConnectionState.CONNECTED then
		return G.FUNCS.exit_overlay_menu()
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 3, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = { account_overlay_inner.node },
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-- Title, tab strip, and whichever tab's content is currently selected --
-- separated from create_UIBox_account_overlay (same split as
-- ui/the_order.lua's the_order_inner vs create_UIBox_the_order) so a tab
-- switch or a history-page fetch only needs to swap this inner element's
-- children in place, not rebuild/reopen the whole overlay.
build_account_overlay_inner = function()
	-- The Chat tab is hidden entirely (not just shown-but-disabled) for an
	-- account that's permanently age-blocked from chat -- there's nothing
	-- for that tab to ever offer them, per MPAPI.connection_state.chat_blocked
	-- (set once during age verification, never changes -- see chat_section's
	-- own comments below).
	local active_tab = _state.tab
	if active_tab == 'chat' and MPAPI.connection_state.chat_blocked then
		active_tab = 'account'
	end

	local tab_cols = {}
	for _, tab in ipairs(TABS) do
		if tab.key ~= 'chat' or not MPAPI.connection_state.chat_blocked then
			local is_selected = (tab.key == active_tab)
			tab_cols[#tab_cols + 1] = {
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.05 },
				nodes = {
					UIBox_button({
						label = { localize(tab.label_key) },
						button = is_selected and 'nil' or 'mpapi_account_select_tab',
						ref_table = { tab = tab.key },
						minw = 3,
						minh = 0.6,
						scale = 0.35,
						chosen = is_selected,
						colour = is_selected and G.C.RED or G.C.UI.BACKGROUND_INACTIVE,
						focus_args = { type = 'none' },
					}),
				},
			}
		end
	end
	local tab_strip = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = tab_cols }

	local content_nodes
	if active_tab == 'chat' then
		content_nodes = build_chat_tab_content()
	elseif active_tab == 'history' then
		content_nodes = build_history_tab_content()
	else
		content_nodes = build_account_tab_content()
	end

	local nodes = { multiplayer_account_title(), tab_strip }
	for _, node in ipairs(content_nodes) do
		nodes[#nodes + 1] = node
	end

	return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = nodes }
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
			discord_linking_buttons(discord_linked),
		},
	}
end

-- Account tab: everything the overlay used to show unconditionally, minus
-- the chat section (moved to its own tab, see build_chat_tab_content below).
build_account_tab_content = function()
	local steam_name = MPAPI.connection_state.steam_name ~= '' and MPAPI.connection_state.steam_name or localize('k_unknown')
	local name_colour = G.C.GREEN
	if MPAPI.connection_state.is_temp then
		steam_name = steam_name .. ' ' .. localize('k_dev_mode_suffix')
		name_colour = G.C.GOLD
	end

	local discord_linked = MPAPI.connection_state.discord_name ~= ''

	return {
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
					},
				},
			},
		},
	}
end

chat_section = function()
	local server_enabled = MPAPI.connection_state.chat_enabled
	local chat_blocked = MPAPI.connection_state.chat_blocked

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

	if server_enabled and not chat_blocked then
		-- Client-side only — chat eligibility is set at account creation and
		-- never changes. A centered button whose own label carries the current
		-- state reads clearer here than a right-aligned toggle switch would.
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.04 },
			nodes = {
				UIBox_button({
					label = { MPAPI.config.chat_enabled and localize('b_chat_on') or localize('b_chat_off') },
					button = 'mpapi_chat_toggle',
					minw = 3, minh = 0.7, scale = 0.4,
					colour = MPAPI.config.chat_enabled and G.C.GREEN or G.C.RED,
					focus_args = { nav = 'wide' },
				}),
			},
		}
	elseif chat_blocked then
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
	else
		-- Not blocked, just never enabled (e.g. a legacy account predating the age-gate rollout)
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.04 },
			nodes = {
				UIBox_button({
					label = { localize('k_chat_enable_title') },
					button = 'mpapi_open_chat_enable',
					minh = 0.7, scale = 0.4, colour = G.C.GREEN,
					focus_args = { nav = 'wide' },
				}),
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

respectful_use_block = function()
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.05, r = 0.1, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.05 },
				nodes = {
					{ n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_respectful_use_title'), scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					} },
					{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_respectful_use_1'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
					} },
					{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_respectful_use_2'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
					} },
					{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_respectful_use_3'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
					} },
				},
			},
		},
	}
end

build_chat_tab_content = function()
	return { chat_section(), respectful_use_block() }
end

-- 'YYYY-MM-DD' out of a run's startedAt timestamp string, same extraction
-- BalatroMultiplayerPvP's ui/replay/replay_browser.lua already uses for its
-- own (unpaginated) replay list, kept split into its own column here rather
-- than concatenated into one label so status can be coloured independently.
format_run_date = function(run)
	return tostring(run.startedAt or ''):match('^(%d%d%d%d%-%d%d%-%d%d)') or '?'
end

match_status_label_and_colour = function(status)
	if status == 'completed' then return localize('k_match_status_completed'), G.C.GREEN end
	if status == 'active' then return localize('k_match_status_active'), G.C.GOLD end
	if status == 'abandoned' then return localize('k_match_status_abandoned'), G.C.UI.TEXT_INACTIVE end
	if status == 'terminated' then return localize('k_match_status_terminated'), G.C.UI.TEXT_INACTIVE end
	return tostring(status), G.C.UI.TEXT_INACTIVE
end

-- One row per run: date / lobby code / status, plus "View Log" (opens the
-- website's visual RLOG viewer -- apps/web's /matches/:runId page, same
-- automatic-decode-and-render viewer the site's own "My Matches" list links
-- to) and "View Replay" (dispatches to whichever mod registered a launcher
-- for this run's modId, see api/playback/registry.lua's register_launcher/
-- launch -- MPAPI itself doesn't know how to bootstrap a replay for any
-- given mod's gamemode). Per-run dynamic G.FUNCS names, same idiom
-- BalatroMultiplayerPvP's replay_browser.lua already uses for its own list.
match_history_row = function(run)
	local status_label, status_colour = match_status_label_and_colour(run.status)
	local can_replay = run.status ~= 'active'

	G.FUNCS['mpapi_match_history_view_log_' .. run.id] = function()
		local conn = MPAPI._internal.conn and MPAPI._internal.conn.connection
		local base_url = conn and conn.api and conn.api.base_url
		if base_url then
			-- Same conn.api.base_url the sibling "View Report" link
			-- (ui/player_report_overlay.lua) already opens a website page
			-- through -- in production the API and website share one origin
			-- (path-routed, matching apps/web's own default `/api/proxy`
			-- same-origin proxying), so this is the site root. In local dev
			-- (a bare API port, no path routing to the separate web dev
			-- server) this opens the API host directly, same known
			-- dev-only gap the report link already has.
			love.system.openURL(base_url .. '/matches/' .. tostring(run.id))
		end
	end

	G.FUNCS['mpapi_match_history_view_replay_' .. run.id] = function()
		G.FUNCS.exit_overlay_menu()
		MPAPI.playback.launch(run.modId, run.id)
	end

	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.05, r = 0.1, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.05 },
		nodes = {
			{ n = G.UIT.C, config = { align = 'cl', minw = 2.2, padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = format_run_date(run), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
			} },
			{ n = G.UIT.C, config = { align = 'cl', minw = 2.2, padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = tostring(run.lobbyCode or '??????'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
			} },
			{ n = G.UIT.C, config = { align = 'cl', minw = 2, padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = status_label, scale = 0.32, colour = status_colour } },
			} },
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
				UIBox_button({
					label = { localize('b_view_log') },
					button = 'mpapi_match_history_view_log_' .. run.id,
					minw = 2, minh = 0.6, scale = 0.3, colour = G.C.BLUE,
				}),
			} },
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
				MPAPI.disableable_button({
					label = { localize('b_view_replay') },
					button = 'mpapi_match_history_view_replay_' .. run.id,
					enabled = can_replay,
					minw = 2, minh = 0.6, scale = 0.3, colour = G.C.GREEN,
				}).node,
			} },
		},
	}
end

build_history_tab_content = function()
	local h = _state.history

	if h.loading then
		return { { n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_match_history_loading'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} } }
	end

	if h.error then
		return {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_match_history_error'), scale = 0.4, colour = G.C.RED } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
				UIBox_button({ label = { localize('b_match_history_retry') }, button = 'mpapi_match_history_retry', minw = 3, minh = 0.6, scale = 0.35, colour = G.C.RED }),
			} },
		}
	end

	if #h.runs == 0 then
		return { { n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_match_history_empty'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} } }
	end

	local rows = {}
	for _, run in ipairs(h.runs) do
		rows[#rows + 1] = match_history_row(run)
	end

	local total_pages = math.max(1, math.ceil(h.total / h.page_size))
	rows[#rows + 1] = {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			MPAPI.disableable_button({
				label = { localize('b_match_history_prev') }, button = 'mpapi_match_history_prev_page',
				enabled = h.page > 1, minw = 1.8, minh = 0.6, scale = 0.3, colour = G.C.BLUE,
			}).node,
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = {
					text = localize('k_match_history_page_label') .. ' ' .. tostring(h.page) .. ' / ' .. tostring(total_pages),
					scale = 0.32, colour = G.C.UI.TEXT_LIGHT,
				} },
			} },
			MPAPI.disableable_button({
				label = { localize('b_match_history_next') }, button = 'mpapi_match_history_next_page',
				enabled = h.page < total_pages, minw = 1.8, minh = 0.6, scale = 0.3, colour = G.C.BLUE,
			}).node,
		},
	}

	return rows
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

fetch_history_page = function(page)
	_state.history.loading = true
	_state.history.error = nil
	account_overlay_inner:update()

	MPAPI.replay.list_mine({ page = page, page_size = _state.history.page_size }, function(err, data)
		_state.history.loading = false
		if err then
			_state.history.error = err
		else
			_state.history.runs = (data and data.runs) or {}
			_state.history.total = (data and data.total) or #_state.history.runs
			_state.history.page = (data and data.page) or page
		end
		account_overlay_inner:update()
	end)
end

G.FUNCS.mpapi_account_select_tab = function(e)
	local tab = e.config and e.config.ref_table and e.config.ref_table.tab
	if not tab or tab == _state.tab then return end
	_state.tab = tab
	if tab == 'history' and #_state.history.runs == 0 and not _state.history.loading and not _state.history.error then
		fetch_history_page(1)
	else
		account_overlay_inner:update()
	end
end

G.FUNCS.mpapi_match_history_retry = function()
	fetch_history_page(_state.history.page)
end

G.FUNCS.mpapi_match_history_prev_page = function()
	if _state.history.page > 1 then fetch_history_page(_state.history.page - 1) end
end

G.FUNCS.mpapi_match_history_next_page = function()
	local total_pages = math.max(1, math.ceil(_state.history.total / _state.history.page_size))
	if _state.history.page < total_pages then fetch_history_page(_state.history.page + 1) end
end

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

G.FUNCS.mpapi_unlink_discord = function(e)
	MPAPI._internal.unlink_discord(function(err, data)
		if err then
			MPAPI.sendWarnMessage('Discord unlink error: ' .. tostring(err))
			return
		end
		MPAPI.sendDebugMessage('Discord unlinked successfully')
	end)
end

-- Button press (not a toggle-widget callback, so there's no new_value handed
-- to us) -- flips the current local config value and re-renders so the
-- button's own label picks up the new "Chat: On"/"Chat: Off" text.
G.FUNCS.mpapi_chat_toggle = function(e)
	local new_value = not MPAPI.config.chat_enabled
	MPAPI._internal.config_set('chat_enabled', new_value)
	MPAPI.chat.on_config_changed(new_value)
	account_overlay_inner:update()
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

account_overlay_inner = MPAPI.ui_element(build_account_overlay_inner)
MPAPI.account_overlay = MPAPI.ui_element(create_UIBox_account_overlay)

-- Fresh-open entry point: resets the tab strip (and any stale Match History
-- page/error state) back to the Account tab. build_fn (build_account_overlay_inner)
-- has no way to tell a genuine fresh :as_overlay() open apart from an
-- in-place :update() triggered by an unrelated event (chat-enable completion,
-- connection-state changes -- see those call sites below), so the reset lives
-- here instead, in the one place that's ONLY ever called on a real open.
function MPAPI.open_account_overlay()
	_state.tab = 'account'
	_state.history = { page = 1, page_size = 10, loading = false, error = nil, runs = {}, total = 0 }
	MPAPI.account_overlay:as_overlay()
end
