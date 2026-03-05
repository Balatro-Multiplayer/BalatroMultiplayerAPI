-- Forward declarations for helper functions
local create_card_rows
local clear_avatar_cards
local populate_page
local avatar_preview_card_click_override
local avatar_preview_card_hover_override
local avatar_selectable_card_click_override
local avatar_selectable_card_hover_override

-----------------------------
-- CONSTANTS
-----------------------------

local ROWS = 3
local COLS = 5
local CARDS_PER_PAGE = ROWS * COLS

local AVATAR_JOKERS = {
	'j_joker',
	'j_mime',
	'j_chaos',
	'j_even_steven',
	'j_odd_todd',
	'j_scholar',
	'j_space',
	'j_egg',
	'j_burglar',
	'j_runner',
	'j_sixth_sense',
	'j_hiker',
	'j_card_sharp',
	'j_madness',
	'j_vampire',
	'j_baron',
	'j_luchador',
	'j_fortune_teller',
	'j_lucky_cat',
	'j_bull',
	'j_ancient',
	'j_mr_bones',
	'j_swashbuckler',
	'j_troubadour',
	'j_throwback',
	'j_ring_master',
	'j_merry_andy',
	'j_idol',
	'j_matador',
	'j_stuntman',
	'j_hack',
	'j_hologram',
	'j_vagabond',
	'j_photograph',
	'j_hallucination',
	'j_baseball',
	'j_sock_and_buskin',
	'j_blueprint',
	'j_invisible',
	'j_brainstorm',
	'j_caino',
	'j_triboulet',
	'j_yorick',
	'j_chicot',
	'j_perkeo',
}

local avatar_centers = {}
for _, id in ipairs(AVATAR_JOKERS) do
	if G.P_CENTERS[id] then
		avatar_centers[#avatar_centers + 1] = G.P_CENTERS[id]
	end
end

-----------------------------
-- STATE VARIABLES
-----------------------------

local _card_rows = {}
local _joker_tables = {}

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_avatar_selection = function()
	_joker_tables = {}

	create_card_rows()
	populate_page(1)

	local total_pages = math.ceil(#avatar_centers / CARDS_PER_PAGE)
	local page_options = {}
	for i = 1, total_pages do
		page_options[#page_options + 1] = localize('k_page') .. ' ' .. tostring(i) .. '/' .. tostring(total_pages)
	end

	local contents = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Choose Avatar', scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = _joker_tables },
		{
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				create_option_cycle({
					options = page_options,
					w = 4.5,
					cycle_shoulders = true,
					opt_callback = 'mpapi_avatar_page',
					current_option = 1,
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
			local center = avatar_centers[i + (j - 1) * COLS + page_offset]
			if not center then
				break
			end
			local card = Card(_card_rows[j].T.x + _card_rows[j].T.w / 2, _card_rows[j].T.y, G.CARD_W, G.CARD_H, nil, center, { mpapi_avatar_selectable = true })
			card.no_ui = true
			card.states.drag.can = false
			_card_rows[j]:emplace(card)
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

avatar_selectable_card_click_override = function(self)
	if self.params.mpapi_avatar_selectable then
		local joker_key = self.config.center.key
		MPAPI._internal.set_preferred_joker(joker_key, function(err, data)
			if err then
				MPAPI.sendWarnMessage('Failed to set avatar: ' .. tostring(err))
				return true
			end
			MPAPI.sendDebugMessage('Avatar set to: ' .. joker_key)
		end)
		G.FUNCS.mpapi_back_to_account_overlay()
		return true
	end
end

avatar_selectable_card_hover_override = function(self)
	if self.params.mpapi_avatar_selectable then
		self:juice_up(0.05, 0.03)
		play_sound('paper1', math.random() * 0.2 + 0.9, 0.35)
		return true
	end
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_avatar_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	clear_avatar_cards()
	populate_page(args.cycle_config.current_option)
end

G.FUNCS.mpapi_open_avatar_selection = function(e)
	G.FUNCS.overlay_menu({
		definition = create_UIBox_avatar_selection(),
	})
end

G.FUNCS.mpapi_back_to_account_overlay = function(e)
	MPAPI.account_overlay:as_overlay()
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
