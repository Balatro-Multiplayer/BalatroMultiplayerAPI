-----------------------------
-- CONSTANTS
-----------------------------

local LAYOUT = {
	-- Tab column
	TAB_W = 2.8, -- min-width of each tab button
	TAB_H = 0.62, -- min-height of each tab button
	TAB_PADDING = 0.05, -- padding between tab buttons
	TAB_TEXT_SCALE = 0.30, -- text scale inside tab buttons

	-- Description column
	CONTENT_W = 9.5, -- min-width of description pane
	CONTENT_H = 6.2, -- min-height of description pane
	DESC_TEXT_SCALE = 0.33, -- body text scale
	DESC_TITLE_SCALE = 0.40, -- tab-title text scale inside description
	DESC_PADDING = 0.15, -- inner padding of description pane
	DESC_LINE_PAD = 0.03, -- vertical padding between text lines

	-- Card display
	CARD_SIZE = 0.60, -- scale factor for Card() objects shown in description

	-- Page selector
	PAGE_CYCLE_W = 5.5, -- width of the option-cycle widget

	-- Overall overlay
	OVERLAY_MINW = 13.4, -- minw passed to create_UIBox_generic_options

	-- Title
	TITLE_SCALE = 0.48,
}

-----------------------------
-- STATE
-----------------------------

local _state = { page = 1, tab = 1 }

-----------------------------
-- PAGE / TAB DATA
-- Each page corresponds to one HTML file.
-- Each tab corresponds to one topic within that page.
-- Fields per tab:
--   label      (string)   button label
--   loc_key    (string)   key into G.localization.descriptions.Other (to_pNtM)
--   jokers     ({key, …}) optional joker card keys
--   consumables({key, …}) optional tarot/spectral/planet card keys
--   tags       ({key, …}) optional tag keys
-----------------------------

local THE_ORDER_PAGES = {

	-- ── 1 ── Skip Tags ────────────────────────────────────────────────────────
	{
		name = 'Skip Tags',
		tabs = {
			{ label = 'Uncommon Tag!', loc_key = 'to_p1t1', tags = { 'tag_uncommon' } },
			{ label = 'Voucher Tag!', loc_key = 'to_p1t2', tags = { 'tag_voucher' } },
			{
				label = 'Riff-raff / Top Up',
				loc_key = 'to_p1t3',
				jokers = { 'j_riff_raff' },
				tags = { 'tag_top_up' },
			},
			{ label = 'Orbital Tag', loc_key = 'to_p1t4', tags = { 'tag_orbital' } },
			{
				label = 'Rare Tag / Wraith',
				loc_key = 'to_p1t5',
				tags = { 'tag_rare' },
				consumables = { 'c_wraith' },
			},
		},
	},

	-- ── 2 ── Consumables ──────────────────────────────────────────────────────
	{
		name = 'Consumables',
		tabs = {
			{ label = 'Aura', loc_key = 'to_p2t1', consumables = { 'c_aura' } },
			{
				label = 'Rare Tag / Wraith',
				loc_key = 'to_p2t2',
				tags = { 'tag_rare' },
				consumables = { 'c_wraith' },
			},
			{ label = 'Judgement', loc_key = 'to_p2t3', consumables = { 'c_judgement' } },
		},
	},

	-- ── 3 ── Card Modifiers ───────────────────────────────────────────────────
	{
		name = 'Card Modifiers',
		tabs = {
			{
				label = 'Glass',
				loc_key = 'to_p3t1',
				consumables = { 'c_familiar', 'c_grim', 'c_incantation' },
			},
			{ label = 'Lucky', loc_key = 'to_p3t2' },
			{ label = 'Purple Seal', loc_key = 'to_p3t3' },
		},
	},

	-- ── 4 ── Decks ────────────────────────────────────────────────────────────
	{
		name = 'Decks',
		tabs = {
			{ label = 'Orange Deck', loc_key = 'to_p4t1', consumables = { 'c_hanged_man' } },
			{ label = 'Purple Deck', loc_key = 'to_p4t2' },
		},
	},

	-- ── 5 ── Jokers ───────────────────────────────────────────────────────────
	{
		name = 'Jokers',
		tabs = {
			{
				label = 'Superposition +',
				loc_key = 'to_p5t1',
				jokers = { 'j_superposition', 'j_vagabond', 'j_cartomancer' },
			},
			{
				label = 'Prob. Jokers',
				loc_key = 'to_p5t2',
				jokers = { 'j_8_ball', 'j_business', 'j_gros_michel', 'j_space', 'j_hallucination', 'j_cavendish' },
			},
			{ label = 'Golden Ticket', loc_key = 'to_p5t3', jokers = { 'j_ticket' } },
			{
				label = 'Seance / Sixth Sense',
				loc_key = 'to_p5t4',
				jokers = { 'j_seance', 'j_sixth_sense' },
			},
			{
				label = 'Riff-Raff / Top Up',
				loc_key = 'to_p5t5',
				jokers = { 'j_riff_raff' },
				tags = { 'tag_top_up' },
			},
			{ label = 'To Do List', loc_key = 'to_p5t6', jokers = { 'j_todo_list' } },
			{ label = 'Invisible Joker', loc_key = 'to_p5t7', jokers = { 'j_invisible' } },
			{ label = 'Bloodstone', loc_key = 'to_p5t8', jokers = { 'j_bloodstone' } },
		},
	},

	-- ── 6 ── Misc ─────────────────────────────────────────────────────────────
	{
		name = 'Misc',
		tabs = {
			{ label = 'Hand Smoothing', loc_key = 'to_p6t1' },
		},
	},

	-- ── 7 ── Packs ────────────────────────────────────────────────────────────
	{
		name = 'Packs',
		tabs = {
			{ label = 'Arcana / Spectral', loc_key = 'to_p7t1' },
			{ label = 'Buffoon Pack', loc_key = 'to_p7t2' },
			{ label = 'Standard Pack', loc_key = 'to_p7t3' },
		},
	},

	-- ── 8 ── Shop Queue ───────────────────────────────────────────────────────
	{
		name = 'Shop Queue',
		tabs = {
			{ label = 'Overview', loc_key = 'to_p8t1' },
			{ label = 'Sub-Queues', loc_key = 'to_p8t2' },
			{ label = 'How It Works', loc_key = 'to_p8t3' },
		},
	},

	-- ── 9 ── Vouchers ─────────────────────────────────────────────────────────
	{
		name = 'Vouchers',
		tabs = {
			{ label = 'Vouchers', loc_key = 'to_p9t1' },
		},
	},
}

-----------------------------
-- HELPER BUILDERS
-----------------------------

-- Returns a CardArea node (G.UIT.O) containing cards for the given center keys.
local function build_card_area_node(keys)
	if not keys or #keys == 0 then
		return nil
	end

	local valid_keys = {}
	for _, key in ipairs(keys) do
		if G.P_CENTERS[key] then
			valid_keys[#valid_keys + 1] = key
		else
			MPAPI.sendWarnMessage('[the_order] unknown center key: ' .. tostring(key))
		end
	end
	if #valid_keys == 0 then
		return nil
	end

	local sz = LAYOUT.CARD_SIZE
	local area = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, #valid_keys * G.CARD_W * sz + 0.1, G.CARD_H * sz, { card_limit = #valid_keys, type = 'title_2', highlight_limit = 0 })

	for _, key in ipairs(valid_keys) do
		local card = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W * sz, G.CARD_H * sz, nil, G.P_CENTERS[key], { bypass_discovery_center = true, bypass_discovery_ui = true, bypass_lock = true })
		area:emplace(card)
	end

	return { n = G.UIT.O, config = { object = area } }
end

-- Builds the objects section (cards + tags) for a tab.
-- All objects are placed in a single horizontal row (beside each other).
-- Returns a row node, or nil if nothing to display.
local function build_objects_section(tab_data)
	local cols = {}

	-- Joker cards
	local joker_node = build_card_area_node(tab_data.jokers)
	if joker_node then
		cols[#cols + 1] = {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.05 },
			nodes = { joker_node },
		}
	end

	-- Consumable cards (tarots / spectrals)
	local consumable_node = build_card_area_node(tab_data.consumables)
	if consumable_node then
		cols[#cols + 1] = {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.05 },
			nodes = { consumable_node },
		}
	end

	-- Tags — each tag becomes its own column in the same row
	if tab_data.tags and #tab_data.tags > 0 then
		for _, key in ipairs(tab_data.tags) do
			if G.P_TAGS and G.P_TAGS[key] then
				local temp_tag = Tag(key, true)
				local tag_ui, _ = temp_tag:generate_UI()
				cols[#cols + 1] = {
					n = G.UIT.C,
					config = { align = 'cm', padding = 0.06 },
					nodes = { tag_ui },
				}
			else
				MPAPI.sendWarnMessage('[the_order] unknown tag key: ' .. tostring(key))
			end
		end
	end

	if #cols == 0 then
		return nil
	end

	-- Single horizontal row containing all objects side by side
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.05 },
		nodes = cols,
	}
end

-- Builds the text section for a tab from its localization key.
-- Reads pre-parsed data from G.localization.descriptions.Other[loc_key].
-- Each text entry supports {C:colorname}text{} inline colour codes.
-- Lines that are only whitespace (" ") are rendered as blank spacers.
local function build_text_section(loc_key)
	if not loc_key then
		return nil
	end

	local desc = G.localization and G.localization.descriptions and G.localization.descriptions.Other and G.localization.descriptions.Other[loc_key]
	if not desc or not desc.text_parsed then
		MPAPI.sendWarnMessage('[the_order] missing loc key: ' .. tostring(loc_key))
		return nil
	end

	local line_rows = {}
	for _, parsed_line in ipairs(desc.text_parsed) do
		-- parsed_line is an array of {strings, control} parts from loc_parse_string.
		-- A spacer line (" ") produces one part whose assembled text is all whitespace.
		if not parsed_line or #parsed_line == 0 then
			line_rows[#line_rows + 1] = { n = G.UIT.R, config = { align = 'cl', minh = 0.18 }, nodes = {} }
		else
			local segments = {}
			local all_whitespace = true
			for _, part in ipairs(parsed_line) do
				local text = ''
				for _, subpart in ipairs(part.strings) do
					if type(subpart) == 'string' then
						text = text .. subpart
					end
				end
				if text ~= '' then
					if not text:match('^%s*$') then
						all_whitespace = false
					end
					segments[#segments + 1] = {
						n = G.UIT.T,
						config = {
							text = text,
							scale = LAYOUT.DESC_TEXT_SCALE,
							colour = part.control.C and loc_colour(part.control.C) or G.C.UI.TEXT_LIGHT,
							shadow = true,
						},
					}
				end
			end
			if all_whitespace or #segments == 0 then
				line_rows[#line_rows + 1] = { n = G.UIT.R, config = { align = 'cl', minh = 0.18 }, nodes = {} }
			else
				line_rows[#line_rows + 1] = {
					n = G.UIT.R,
					config = { align = 'cl', padding = LAYOUT.DESC_LINE_PAD },
					nodes = segments,
				}
			end
		end
	end

	if #line_rows == 0 then
		return nil
	end
	return {
		n = G.UIT.C,
		config = { align = 'tl', padding = 0.05 },
		nodes = line_rows,
	}
end

-----------------------------
-- INNER CONTENT BUILDER
-- Returns the ROOT for the_order_inner (tabs col + description col).
-----------------------------

local function build_the_order_inner()
	local page_data = THE_ORDER_PAGES[_state.page]
	local tab_data = page_data.tabs[_state.tab] or page_data.tabs[1]

	-- ── Left column: tab buttons ──────────────────────────────────────────
	local tab_button_rows = {}
	for i, tab in ipairs(page_data.tabs) do
		local is_selected = (i == _state.tab)
		tab_button_rows[#tab_button_rows + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = LAYOUT.TAB_PADDING },
			nodes = {
				UIBox_button({
					label = { tab.label },
					button = is_selected and 'nil' or 'the_order_select_tab',
					ref_table = { idx = i },
					minw = LAYOUT.TAB_W,
					minh = LAYOUT.TAB_H,
					scale = LAYOUT.TAB_TEXT_SCALE,
					col = true,
					choice = true,
					chosen = is_selected,
					colour = is_selected and G.C.RED or G.C.UI.BACKGROUND_INACTIVE,
					focus_args = { type = 'none' },
				}),
			},
		}
	end

	local tabs_col = {
		n = G.UIT.C,
		config = {
			align = 'tm',
			padding = 0.08,
			minw = LAYOUT.TAB_W + 0.2,
			colour = G.C.L_BLACK,
			r = 0.1,
			emboss = 0.05,
		},
		nodes = tab_button_rows,
	}

	-- ── Right column: description ─────────────────────────────────────────
	-- Layout (top to bottom): title, divider, full-width text, objects row.

	local text_section = build_text_section(tab_data.loc_key)
	local objects_section = build_objects_section(tab_data)

	local desc_inner = {
		-- Title
		{
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.06 },
			nodes = {
				{
					n = G.UIT.T,
					config = {
						text = tab_data.label,
						scale = LAYOUT.DESC_TITLE_SCALE,
						colour = G.C.UI.TEXT_LIGHT,
						shadow = true,
					},
				},
			},
		},
		-- Thin divider
		{
			n = G.UIT.R,
			config = { minh = 0.04, minw = LAYOUT.CONTENT_W - 0.3, colour = G.C.UI.BACKGROUND_INACTIVE },
			nodes = {},
		},
		-- Full-width text body
		text_section and {
			n = G.UIT.R,
			config = { align = 'tl', padding = 0.06 },
			nodes = { text_section },
		} or nil,
		-- Objects (cards + tags) below text, all in one horizontal row
		objects_section and {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.08 },
			nodes = { objects_section },
		} or nil,
	}

	local description_col = {
		n = G.UIT.C,
		config = {
			align = 'tm',
			padding = LAYOUT.DESC_PADDING,
			minw = LAYOUT.CONTENT_W,
			minh = LAYOUT.CONTENT_H,
			colour = G.C.BLACK,
			r = 0.1,
			emboss = 0.05,
		},
		nodes = desc_inner,
	}

	-- ── Page selector ────────────────────────────────────────────────────
	local page_options = {}
	for _, page in ipairs(THE_ORDER_PAGES) do
		page_options[#page_options + 1] = page.name
	end

	local page_selector_row = {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			create_option_cycle({
				options = page_options,
				w = LAYOUT.PAGE_CYCLE_W,
				cycle_shoulders = true,
				opt_callback = 'the_order_change_page',
				current_option = _state.page,
				colour = G.C.RED,
				no_pips = true,
				focus_args = { snap_to = true, nav = 'wide' },
			}),
		},
	}

	-- ── Assemble: title / tabs+desc / page selector stacked vertically ────
	return {
		n = G.UIT.ROOT,
		config = { align = 'cm', colour = G.C.CLEAR },
		nodes = {
			-- Title
			{
				n = G.UIT.R,
				config = { align = 'cm', padding = 0.08 },
				nodes = {
					{
						n = G.UIT.T,
						config = {
							text = "What Does 'The Order' Do?",
							scale = LAYOUT.TITLE_SCALE,
							colour = G.C.UI.TEXT_LIGHT,
							shadow = true,
						},
					},
				},
			},
			-- Tabs + description
			{
				n = G.UIT.R,
				config = { align = 'cm', padding = 0.1 },
				nodes = {
					tabs_col,
					{ n = G.UIT.C, config = { minw = 0.12 } }, -- gap
					description_col,
				},
			},
			-- Page selector
			page_selector_row,
		},
	}
end

-----------------------------
-- REACTIVE ELEMENT
-----------------------------

local the_order_inner = MPAPI.ui_element(build_the_order_inner)

-----------------------------
-- FULL OVERLAY BUILDER
-----------------------------

local function create_UIBox_the_order()
	-- the_order_inner already contains title, tabs+desc, and page selector.
	-- Pass it as the sole contents item so create_UIBox_generic_options doesn't
	-- fight us with its own R wrapper.
	return create_UIBox_generic_options({
		minw = LAYOUT.OVERLAY_MINW,
		snap_back = true,
		contents = { the_order_inner.node },
	})
end

-----------------------------
-- G.FUNCS CALLBACKS
-----------------------------

-- Open The Order overlay (resets to page 1, tab 1).
G.FUNCS.the_order_open = function(e)
	_state.page = 1
	_state.tab = 1
	G.FUNCS.overlay_menu({ definition = create_UIBox_the_order() })
end

-- Select a tab within the current page.
G.FUNCS.the_order_select_tab = function(e)
	local idx = e.config and e.config.ref_table and e.config.ref_table.idx
	if idx and idx ~= _state.tab then
		_state.tab = idx
		the_order_inner:update()
	end
end

-- Change page via the option cycle at the bottom.
-- `args` is the standard option_cycle callback table: { to_key, to_val, … }
G.FUNCS.the_order_change_page = function(args)
	local new_page = args and args.to_key
	if new_page and new_page ~= _state.page then
		_state.page = new_page
		_state.tab = 1
		the_order_inner:update()
	end
end

-----------------------------
-- MAIN MENU BUTTON
-----------------------------

local function build_the_order_button()
	return {
		n = G.UIT.ROOT,
		config = { align = 'cm', colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.R,
				config = {
					align = 'cm',
					padding = 0.08,
					r = 0.1,
					emboss = 0.08,
					colour = G.C.JOKER_GREY,
					minw = 2.5,
					maxw = 2.5,
				},
				nodes = {
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = {
							{
								n = G.UIT.T,
								config = {
									text = 'The Order',
									scale = 0.3,
									colour = G.C.UI.TEXT_LIGHT,
									shadow = true,
								},
							},
						},
					},
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.05 },
						nodes = {
							{
								n = G.UIT.C,
								config = {
									align = 'cm',
									padding = 0.08,
									minw = 2.2,
									maxw = 2.2,
									minh = 0.6,
									r = 0.1,
									hover = true,
									shadow = true,
									colour = G.C.ORANGE,
									button = 'the_order_open',
								},
								nodes = {
									{
										n = G.UIT.T,
										config = {
											text = 'Ruleset Reference',
											scale = 0.28,
											colour = G.C.UI.TEXT_LIGHT,
											shadow = true,
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
end

MPAPI.the_order_button = MPAPI.ui_element(build_the_order_button)

local function attach_the_order_button()
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		func = function()
			MPAPI.the_order_button:as_uibox({ align = 'tri', offset = { x = 10, y = 0 }, major = G.ROOM_ATTACH, bond = 'Weak' }, function(uibox)
				uibox.alignment.offset.x = 0
				uibox:align_to_major()
			end)
			return true
		end,
	}))
end

-- Wrap set_main_menu_UI to attach our button each time the main menu is shown.
local _the_order_set_main_menu_UI_ref = set_main_menu_UI
set_main_menu_UI = function()
	_the_order_set_main_menu_UI_ref()
	attach_the_order_button()
end
