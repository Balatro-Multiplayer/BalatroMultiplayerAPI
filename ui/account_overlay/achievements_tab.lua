-- The account overlay's Achievements tab: every avatar from the catalog
-- (api/avatars/catalog.lua), grouped by goal kind, with its goal, progress
-- and whether it is unlocked. ui/account_overlay.lua owns the tab strip and
-- calls build() for the content; this file owns the tab's paging.
--
-- Load order inside ui/ is not fixed: everything from the overlay and the
-- catalog is looked up when used, not when this file loads.

-- Forward declarations for helper functions
local entry_row
local group_header_row
local progress_bar
local summary_rows
local paging_row

-----------------------------
-- CONSTANTS
-----------------------------

local ENTRIES_PER_PAGE = 6
local ROW_W = 11
local BAR_W = 3
local CARD_SCALE = 0.3

-----------------------------
-- STATE
-----------------------------

local _state = {
	page = 1,
}

-----------------------------
-- PURE
-----------------------------

local function goals()
	return MPAPI.avatars.goals
end

local function text(key, vars)
	return goals().localized(key, vars) or key
end

-- The catalog's entries in tab order: by group (Goals.GROUP_ORDER), then in
-- the catalog's own (sheet) order. Each comes with its group.
local function grouped_entries(catalog)
	local Goals = goals()
	local by_group = {}
	for _, entry in ipairs(catalog.avatars) do
		local group = Goals.group_of(entry)
		by_group[group] = by_group[group] or {}
		table.insert(by_group[group], entry)
	end
	local ordered = {}
	for _, group in ipairs(Goals.GROUP_ORDER) do
		for _, entry in ipairs(by_group[group] or {}) do
			ordered[#ordered + 1] = { entry = entry, group = group }
		end
	end
	return ordered
end

local function page_count(n_entries)
	return math.max(1, math.ceil(n_entries / ENTRIES_PER_PAGE))
end

local function avatar_name(id)
	local ok, name = pcall(localize, { type = 'name_text', set = 'Joker', key = id })
	if ok and type(name) == 'string' and name ~= '' and name ~= 'ERROR' then
		return name
	end
	return id
end

-----------------------------
-- UI FUNCTIONS
-----------------------------

local function avatar_card(id, locked)
	local center = G.P_CENTERS[id]
	if not center then
		return nil
	end
	local card = Card(0, 0, G.CARD_W * CARD_SCALE, G.CARD_H * CARD_SCALE, nil, center, {
		bypass_discovery_center = true,
		bypass_lock = true,
		mpapi_achievements_card = true,
	})
	card.no_ui = true
	card.greyed = locked or nil
	card.states.drag.can = false
	card.states.click.can = false
	card.states.hover.can = false
	return card
end

progress_bar = function(goal)
	local fraction = goals().fraction(goal)
	local fill = {}
	if fraction > 0 then
		fill[1] = { n = G.UIT.C, config = { minw = BAR_W * fraction, minh = 0.16, r = 0.05, colour = G.C.GREEN } }
	end
	return { n = G.UIT.C, config = { align = 'cl', minw = BAR_W, maxw = BAR_W, minh = 0.16, r = 0.05, colour = G.C.BLACK }, nodes = fill }
end

-- Unlocked / Selected, or how far along a locked one is.
local function status_node(entry, selected)
	local Goals = goals()
	local label, colour
	if entry.id == selected then
		label, colour = text('k_avatar_selected'), G.C.GOLD
	elseif entry.unlocked then
		label, colour = text('k_avatar_unlocked'), G.C.GREEN
	else
		label, colour = Goals.progress_text(entry.goal) or text('k_avatar_locked'), G.C.UI.TEXT_INACTIVE
	end
	return { n = G.UIT.T, config = { text = label, scale = 0.3, colour = colour } }
end

entry_row = function(entry, selected)
	local Goals = goals()
	local card = avatar_card(entry.id, not entry.unlocked)
	local show_bar = not entry.unlocked and Goals.has_shown_progress(entry.goal)
	local name_colour = entry.unlocked and G.C.UI.TEXT_LIGHT or G.C.UI.TEXT_INACTIVE

	local status_nodes = { status_node(entry, selected) }
	local status_col = { n = G.UIT.R, config = { align = 'cr' }, nodes = status_nodes }
	local bar_col = show_bar and { n = G.UIT.R, config = { align = 'cr', padding = 0.03 }, nodes = { progress_bar(entry.goal) } } or nil

	return {
		n = G.UIT.R,
		config = { id = 'mpapi_achievement_' .. entry.id, align = 'cm', padding = 0.04, r = 0.1, minw = ROW_W, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.03 },
		nodes = {
			{ n = G.UIT.C, config = { align = 'cm', minw = 0.8 }, nodes = card and {
				{ n = G.UIT.O, config = { object = card } },
			} or {} },
			{ n = G.UIT.C, config = { align = 'cl', minw = 6, maxw = 6, padding = 0.03 }, nodes = {
				{ n = G.UIT.R, config = { align = 'cl' }, nodes = {
					{ n = G.UIT.T, config = { text = avatar_name(entry.id), scale = 0.36, colour = name_colour, shadow = true } },
				} },
				{ n = G.UIT.R, config = { align = 'cl' }, nodes = {
					{ n = G.UIT.T, config = { text = Goals.text(entry.goal), scale = 0.28, colour = G.C.UI.TEXT_LIGHT } },
				} },
			} },
			{ n = G.UIT.C, config = { align = 'cr', minw = BAR_W + 0.2 }, nodes = { status_col, bar_col } },
		},
	}
end

group_header_row = function(group)
	return { n = G.UIT.R, config = { align = 'cl', padding = 0.04, minw = ROW_W }, nodes = {
		{ n = G.UIT.T, config = { text = goals().group_label(group), scale = 0.32, colour = G.C.GOLD, shadow = true } },
	} }
end

summary_rows = function(catalog)
	local Catalog = MPAPI.avatars.catalog
	local rows = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			{ n = G.UIT.T, config = {
				text = text('k_avatars_unlocked_count', { Catalog.unlocked_count(catalog), #catalog.avatars }),
				scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true,
			} },
		} },
	}
	local note_key = nil
	if catalog.source == Catalog.Source.FALLBACK then
		note_key = 'k_avatars_unavailable'
	elseif not catalog.enabled then
		note_key = 'k_avatars_paused'
	end
	if note_key then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = text(note_key), scale = 0.3, colour = G.C.ORANGE } },
		} }
	end
	return rows
end

paging_row = function(page, pages)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			MPAPI.disableable_button({
				label = { localize('b_match_history_prev') }, button = 'mpapi_achievements_prev_page',
				enabled = page > 1, minw = 1.8, minh = 0.6, scale = 0.3, colour = G.C.BLUE,
			}).node,
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = {
					text = localize('k_page') .. ' ' .. tostring(page) .. '/' .. tostring(pages),
					scale = 0.32, colour = G.C.UI.TEXT_LIGHT,
				} },
			} },
			MPAPI.disableable_button({
				label = { localize('b_match_history_next') }, button = 'mpapi_achievements_next_page',
				enabled = page < pages, minw = 1.8, minh = 0.6, scale = 0.3, colour = G.C.BLUE,
			}).node,
		},
	}
end

-- The tab's content rows, for ui/account_overlay.lua.
local function build()
	local Catalog = MPAPI.avatars.catalog
	if Catalog.status() == Catalog.Status.LOADING and not Catalog.has_catalog() then
		return { { n = G.UIT.R, config = { align = 'cm', padding = 0.3 }, nodes = {
			{ n = G.UIT.T, config = { text = text('k_avatars_loading'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} } }
	end

	local catalog = Catalog.get()
	local ordered = grouped_entries(catalog)
	local pages = page_count(#ordered)
	_state.page = math.max(1, math.min(_state.page, pages))

	local rows = summary_rows(catalog)
	local first = (_state.page - 1) * ENTRIES_PER_PAGE + 1
	local last_group = nil
	for i = first, math.min(#ordered, first + ENTRIES_PER_PAGE - 1) do
		local item = ordered[i]
		if item.group ~= last_group then
			rows[#rows + 1] = group_header_row(item.group)
			last_group = item.group
		end
		rows[#rows + 1] = entry_row(item.entry, catalog.selected)
	end
	rows[#rows + 1] = paging_row(_state.page, pages)
	return rows
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

local function refresh_tab()
	if MPAPI._internal.refresh_account_overlay then
		MPAPI._internal.refresh_account_overlay('achievements')
	end
end

-- The tab was opened (fresh or switched to): start on page 1 with the
-- latest catalog.
local function on_open()
	_state.page = 1
	MPAPI.avatars.catalog.refresh()
end

G.FUNCS.mpapi_achievements_prev_page = function()
	if _state.page <= 1 then return end
	_state.page = _state.page - 1
	refresh_tab()
end

G.FUNCS.mpapi_achievements_next_page = function()
	_state.page = _state.page + 1
	refresh_tab()
end

MPAPI._internal.account_tabs = MPAPI._internal.account_tabs or {}
MPAPI._internal.account_tabs.achievements = {
	build = build,
	on_open = on_open,
	-- For tests.
	grouped_entries = grouped_entries,
	page = function()
		return _state.page
	end,
	ENTRIES_PER_PAGE = ENTRIES_PER_PAGE,
}

-- The catalog listener is registered once the catalog is there (api/ loads
-- before ui/, so it is).
if MPAPI.avatars and MPAPI.avatars.catalog then
	MPAPI.avatars.catalog.on_change(refresh_tab)
end
