-- Per-player overlay for a single lobby player, opened from a lobby card
-- click (ui/lobby.lua's lobby_card_click_override, including from within
-- ui/lobby_info_overlay.lua's card grid). A click-triggered overlay rather
-- than living in the card's hover popup, since h_popups are a passive hover
-- display not reliably interactive. Tabbed: "Actions" (mute/report/kick) and
-- "Mods" (that specific player's installed mods, paginated).
local build_actions_tab_content
local build_mods_tab_content
local build_player_overlay_inner
local player_overlay_title
local player_overlay_inner

-----------------------------
-- STATE
-----------------------------

local _target_id = nil
local _target_name = nil
local _submitting = false

local _state = {
	tab = 'actions', -- 'actions' | 'mods'
	mods_page = 1,
}

local TABS = {
	{ key = 'actions', label_key = 'k_player_overlay_tab_actions' },
	{ key = 'mods', label_key = 'k_player_overlay_tab_mods' },
}

local MODS_PER_PAGE = 10

-- mods: array of "ModId-version" strings (see MPAPI.collect_installed_mods).
-- Special mods (Steamodded/Lovely/Multiplayer/Preview) sorted first in that
-- fixed order, then the rest alphabetically -- ports the bucketing logic
-- (not the code) from the now-deleted BalatroMultiplayerPvP/ui/game/
-- lobby_info.lua's PVP.UI.modlist_to_view, minus its banned-mods-red-
-- colouring (a PvP anti-cheat concept, out of scope for MPAPI's generic
-- default).
local SPECIAL_MOD_PREFIXES = { 'Steamodded', 'Lovely', 'Multiplayer', 'Preview' }

function MPAPI._sort_modlist(mods)
	mods = mods or {}
	local special = {}
	local other = {}
	for _, entry in ipairs(mods) do
		local matched = false
		for _, prefix in ipairs(SPECIAL_MOD_PREFIXES) do
			if not special[prefix] and entry:sub(1, #prefix) == prefix then
				special[prefix] = entry
				matched = true
				break
			end
		end
		if not matched then
			other[#other + 1] = entry
		end
	end
	table.sort(other)

	local result = {}
	for _, prefix in ipairs(SPECIAL_MOD_PREFIXES) do
		if special[prefix] then
			result[#result + 1] = special[prefix]
		end
	end
	for _, entry in ipairs(other) do
		result[#result + 1] = entry
	end
	return result
end

-- "ModId-version" -> "{display name} ({version})". The wire format is always
-- id .. '-' .. version (MPAPI.collect_installed_mods), and mod ids never
-- contain a hyphen (Steamodded convention) while versions sometimes do (e.g.
-- "1.0.0~BETA-1620a"), so splitting on the FIRST hyphen reliably recovers
-- both. The display name only resolves if we have that mod installed
-- locally too (SMODS.Mods is our own client's mod table, not the remote
-- player's) -- falls back to the raw id otherwise, which is still every bit
-- as identifying as what used to be shown.
function MPAPI._format_mod_display(entry)
	local id, version = entry:match('^([^%-]+)%-(.+)$')
	if not id then
		return entry
	end
	local mod = SMODS and SMODS.Mods and SMODS.Mods[id]
	local name = (mod and mod.name) or id
	return name .. ' (' .. version .. ')'
end

-----------------------------
-- UI BUILD FUNCTIONS
-----------------------------

player_overlay_title = function()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = _target_name or '', scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }
end

build_actions_tab_content = function()
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

	return rows
end

build_mods_tab_content = function()
	local lobby = MPAPI.get_current_lobby()
	local player_data = _target_id and lobby and lobby._players[_target_id]
	local sorted = MPAPI._sort_modlist(player_data and player_data.mods)

	if #sorted == 0 then
		return { { n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_lobby_info_no_mods'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} } }
	end

	local total_pages = math.max(1, math.ceil(#sorted / MODS_PER_PAGE))
	if _state.mods_page > total_pages then
		_state.mods_page = total_pages
	end
	local page_offset = (_state.mods_page - 1) * MODS_PER_PAGE

	local rows = {}
	for i = 1, MODS_PER_PAGE do
		local entry = sorted[page_offset + i]
		if not entry then
			break
		end
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cl', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = MPAPI._format_mod_display(entry), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
		} }
	end

	if total_pages > 1 then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
			MPAPI.disableable_button({
				label = { '<' }, button = 'mpapi_player_overlay_mods_prev_page',
				enabled = _state.mods_page > 1, minw = 1.2, minh = 0.6, scale = 0.4, colour = G.C.BLUE,
			}).node,
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = { text = tostring(_state.mods_page) .. ' / ' .. tostring(total_pages), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
			} },
			MPAPI.disableable_button({
				label = { '>' }, button = 'mpapi_player_overlay_mods_next_page',
				enabled = _state.mods_page < total_pages, minw = 1.2, minh = 0.6, scale = 0.4, colour = G.C.BLUE,
			}).node,
		} }
	end

	return rows
end

build_player_overlay_inner = function()
	local tab_cols = {}
	for _, tab in ipairs(TABS) do
		local is_selected = (tab.key == _state.tab)
		tab_cols[#tab_cols + 1] = {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.05 },
			nodes = {
				UIBox_button({
					label = { localize(tab.label_key) },
					button = is_selected and 'nil' or 'mpapi_player_overlay_select_tab',
					ref_table = { tab = tab.key },
					minw = 3, minh = 0.6, scale = 0.35,
					chosen = is_selected,
					colour = is_selected and G.C.RED or G.C.UI.BACKGROUND_INACTIVE,
					focus_args = { type = 'none' },
				}),
			},
		}
	end
	local tab_strip = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = tab_cols }

	local content_rows = _state.tab == 'mods' and build_mods_tab_content() or build_actions_tab_content()

	local rows = { player_overlay_title(), tab_strip }
	for _, row in ipairs(content_rows) do
		rows[#rows + 1] = row
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

G.FUNCS.mpapi_player_overlay_select_tab = function(e)
	local tab = e.config and e.config.ref_table and e.config.ref_table.tab
	if not tab or tab == _state.tab then
		return
	end
	_state.tab = tab
	if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
end

G.FUNCS.mpapi_player_overlay_mods_prev_page = function()
	if _state.mods_page > 1 then
		_state.mods_page = _state.mods_page - 1
		if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
	end
end

G.FUNCS.mpapi_player_overlay_mods_next_page = function()
	_state.mods_page = _state.mods_page + 1
	if MPAPI.player_mute_overlay then MPAPI.player_mute_overlay:update() end
end

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

MPAPI.player_mute_overlay = MPAPI.ui_element(build_player_overlay_inner)

-- Called from ui/lobby.lua's lobby_card_click_override with the clicked
-- player's id/display name.
function MPAPI.open_player_mute_overlay(player_id, player_name)
	_target_id = player_id
	_target_name = player_name or 'Unknown'
	_submitting = false
	_state.tab = 'actions'
	_state.mods_page = 1
	MPAPI.player_mute_overlay:as_overlay()
end
