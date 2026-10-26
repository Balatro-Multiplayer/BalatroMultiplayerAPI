-- Forward declarations for helper functions
local create_card_rows
local avatar_center
local clear_avatar_cards
local populate_page
local avatar_preview_card_click_override
local avatar_preview_card_hover_override
local avatar_selectable_card_click_override
local avatar_selectable_card_hover_override
local calculate_avatar_entries
local locked_avatar_popup
local refresh_open_picker

-----------------------------
-- CONSTANTS
-----------------------------

local ROWS = 3
local COLS = 5
local CARDS_PER_PAGE = ROWS * COLS

-----------------------------
-- STATE VARIABLES
-----------------------------

local _card_rows = {}
local _joker_tables = {}
-- The catalog entries shown ({ id, unlocked, goal }), in catalog order, and
-- which one is the current avatar.
local _avatar_entries = {}
local _selected = nil
local _page = 1

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_avatar_selection = function()
	_joker_tables = {}

	calculate_avatar_entries()
	create_card_rows()
	local total_pages = math.max(1, math.ceil(#_avatar_entries / CARDS_PER_PAGE))
	_page = math.max(1, math.min(_page, total_pages))
	populate_page(_page)

	local page_options = {}
	for i = 1, total_pages do
		page_options[#page_options + 1] = localize('k_page') .. ' ' .. tostring(i) .. '/' .. tostring(total_pages)
	end

	local contents = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_choose_avatar'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		} },
		{ n = G.UIT.R, config = { id = 'mpapi_avatar_selection', align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = _joker_tables },
		{
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				create_option_cycle({
					options = page_options,
					w = 4.5,
					cycle_shoulders = true,
					opt_callback = 'mpapi_avatar_page',
					current_option = _page,
					colour = MPAPI.C.MP_EDITION,
					no_pips = true,
					focus_args = { snap_to = true, nav = 'wide' },
				}),
			},
		},
	}

	return create_UIBox_generic_options({
		back_func = 'mpapi_back_to_account_overlay',
		contents = contents,
	})
end

-- Every catalog avatar this client can draw (api/avatars/catalog.lua: the
-- server's list, or the fallback for a server without one), except a locked
-- one the player can never earn (MPAPI.avatars.goals.obtainable).
local function drawable_entries(catalog)
	local entries = {}
	for _, entry in ipairs(catalog.avatars) do
		if G.P_CENTERS[entry.id] and MPAPI.avatars.goals.obtainable(entry) then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

calculate_avatar_entries = function()
	local catalog = MPAPI.avatars.catalog.get()
	_selected = catalog.selected
	_avatar_entries = drawable_entries(catalog)
end

create_card_rows = function()
	_card_rows = {}
	for j = 1, ROWS do
		_card_rows[j] = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, COLS * G.CARD_W, 0.95 * G.CARD_H, { card_limit = COLS, type = 'title', highlight_limit = 0, collection = true })
		_joker_tables[#_joker_tables + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.07, no_fill = true },
			nodes = {
				{ n = G.UIT.O, config = { object = _card_rows[j] } },
			},
		}
	end
end

-- The center an avatar card is built from. A locked one is a view of the
-- joker that reads as locked and undiscovered, whatever the player's own
-- profile says, so the card shows the locked sprite (and no soul layer);
-- its key and everything else still come from the joker.
avatar_center = function(id, locked)
	local center = G.P_CENTERS[id]
	if not locked then
		return center
	end
	return setmetatable({ unlocked = false, discovered = false }, { __index = center })
end

clear_avatar_cards = function()
	for j = 1, #_card_rows do
		for i = #_card_rows[j].cards, 1, -1 do
			local c = _card_rows[j]:remove_card(_card_rows[j].cards[i])
			c:remove()
			c = nil
		end
	end
end

populate_page = function(page)
	local page_offset = CARDS_PER_PAGE * (page - 1)
	for i = 1, COLS do
		for j = 1, ROWS do
			local entry = _avatar_entries[i + (j - 1) * COLS + page_offset]
			if not entry then
				break
			end
			local locked = not entry.unlocked
			local card = Card(_card_rows[j].T.x + _card_rows[j].T.w / 2, _card_rows[j].T.y, G.CARD_W, G.CARD_H, nil, avatar_center(entry.id, locked), {
				mpapi_avatar_selectable = true,
				mpapi_avatar_locked = locked or nil,
				mpapi_avatar_goal = entry.goal,
				-- Locked: Card:set_sprites draws the center as the vanilla
				-- locked joker, as long as it is not told to bypass that.
				bypass_discovery_center = not locked or nil,
				bypass_lock = true,
			})
			card.no_ui = true
			card.states.drag.can = false
			-- The current avatar: raised.
			_card_rows[j]:emplace(card)
			if entry.id == _selected then
				card.highlighted = true
			end
		end
	end
end

avatar_preview_card_click_override = function(self)
	if self.params.mpapi_avatar_preview then
		G.FUNCS.mpapi_open_avatar_selection()
		return true
	end
end

avatar_preview_card_hover_override = function(self)
	if self.params.mpapi_avatar_preview then
		self:juice_up(0.05, 0.03)
		return true
	end
end

-- A locked avatar can't be picked (the server refuses it too). An unlocked
-- one is sent to the server; the catalog is refreshed either way, so a pick
-- the server refused shows as it really is.
avatar_selectable_card_click_override = function(self)
	if self.params.mpapi_avatar_selectable then
		if self.params.mpapi_avatar_locked then
			self:juice_up(0.1, 0.1)
			play_sound('cancel', 0.8, 0.5)
			return true
		end
		local joker_key = self.config.center.key
		MPAPI._internal.set_preferred_joker(joker_key, function(err, data)
			if err then
				MPAPI.sendWarnMessage('Failed to set avatar: ' .. tostring(err.message or err))
			else
				MPAPI.sendDebugMessage('Avatar set to: ' .. joker_key)
				MPAPI.avatars.catalog.note_selected(joker_key)
			end
			MPAPI.avatars.catalog.refresh()
		end)
		G.FUNCS.mpapi_back_to_account_overlay()
		return true
	end
end

-- The hover box for a locked avatar: its name, the goal and how far along.
locked_avatar_popup = function(card)
	local Goals = MPAPI.avatars.goals
	local goal = card.params.mpapi_avatar_goal
	local rows = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = localize({ type = 'name_text', set = 'Joker', key = card.config.center.key }), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = Goals.text(goal), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
		} },
	}
	local progress = Goals.progress_text(goal)
	if progress then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = progress, scale = 0.32, colour = G.C.GOLD } },
		} }
	end
	return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.1, r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = rows }
end

avatar_selectable_card_hover_override = function(self)
	if self.params.mpapi_avatar_selectable then
		self:juice_up(0.05, 0.03)
		if self.params.mpapi_avatar_locked then
			self.config.h_popup = locked_avatar_popup(self)
			self.config.h_popup_config = self:align_h_popup()
			Node.hover(self)
		else
			play_sound('paper1', math.random() * 0.2 + 0.9, 0.35)
		end
		return true
	end
end

-- What the shown cards depend on, to tell whether a new catalog changes them.
local function entries_signature(entries, selected)
	local parts = { tostring(selected) }
	for _, entry in ipairs(entries) do
		parts[#parts + 1] = entry.id .. (entry.unlocked and '+' or '-')
	end
	return table.concat(parts, ',')
end

-- A catalog that changes while the picker is open (the fetch it started on
-- opening): rebuild the picker, which may now have a different page count.
refresh_open_picker = function()
	if not (G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID('mpapi_avatar_selection')) then
		return
	end
	local shown = entries_signature(_avatar_entries, _selected)
	local catalog = MPAPI.avatars.catalog.get()
	if entries_signature(drawable_entries(catalog), catalog.selected) == shown then
		return
	end
	G.FUNCS.overlay_menu({
		definition = create_UIBox_avatar_selection(),
	})
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_avatar_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	_page = args.cycle_config.current_option
	clear_avatar_cards()
	populate_page(_page)
end

G.FUNCS.mpapi_open_avatar_selection = function(e)
	_page = 1
	G.FUNCS.overlay_menu({
		definition = create_UIBox_avatar_selection(),
	})
	MPAPI.avatars.catalog.refresh()
end

G.FUNCS.mpapi_back_to_account_overlay = function(e)
	MPAPI.open_account_overlay()
end

-----------------------------
-- OVERRIDES
-----------------------------

local _card_click_ref = Card.click
function Card:click()
	if avatar_preview_card_click_override(self) then
		return
	end
	if avatar_selectable_card_click_override(self) then
		return
	end
	_card_click_ref(self)
end

local _card_hover_ref = Card.hover
function Card:hover()
	if avatar_preview_card_hover_override(self) then
		return
	end
	if avatar_selectable_card_hover_override(self) then
		return
	end
	_card_hover_ref(self)
end

if MPAPI.avatars and MPAPI.avatars.catalog then
	MPAPI.avatars.catalog.on_change(refresh_open_picker)
end
