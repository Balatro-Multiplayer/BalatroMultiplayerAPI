local _card_click_ref = Card.click
function Card:click()
	if self.params.mpapi_avatar_preview then
		G.FUNCS.mpapi_open_avatar_selection()
		return
	end
	if self.params.mpapi_avatar_selectable then
		local joker_key = self.config.center.key
		MPAPI.set_preferred_joker(joker_key, function(err, data)
			if err then
				MPAPI.sendWarnMessage('Failed to set avatar: ' .. tostring(err))
				return
			end
			MPAPI.sendDebugMessage('Avatar set to: ' .. joker_key)
		end)
		G.FUNCS.mpapi_back_to_account_overlay()
		return
	end
	_card_click_ref(self)
end

local _card_hover_ref = Card.hover
function Card:hover()
	if self.params.mpapi_avatar_preview then
		self:juice_up(0.05, 0.03)
		return
	end
	if self.params.mpapi_avatar_selectable then
		self:juice_up(0.05, 0.03)
		play_sound('paper1', math.random() * 0.2 + 0.9, 0.35)
		return
	end
	_card_hover_ref(self)
end

local ROWS = 3
local COLS = 5
local CARDS_PER_PAGE = ROWS * COLS

local AVATAR_JOKERS = {
	'j_joker',
	'j_mime',
	'j_chaos',
	'j_space',
	'j_scholar',
	'j_egg',
	'j_burglar',
	'j_runner',
	'j_sixth_sense',
	'j_hiker',
	'j_card_sharp',
	'j_madness',
	'j_vampire',
	'j_baron',
	'j_fortune_teller',
	'j_luchador',
	'j_lucky_cat',
	'j_bull',
	'j_swashbuckler',
	'j_throwback',
	'j_mr_bones',
	'j_ring_master',
	'j_idol',
	'j_merry_andy',
	'j_stuntman',
	'j_matador',
	'j_troubadour',
	'j_ancient',
	'j_even_steven',
	'j_odd_todd',
	'j_hack',
	'j_vagabond',
	'j_hologram',
	'j_photograph',
	'j_hallucination',
	'j_baseball',
	'j_sock_and_buskin',
	'j_blueprint',
	'j_brainstorm',
	'j_invisible',
	'j_chicot',
	'j_perkeo',
	'j_triboulet',
	'j_yorick',
	'j_caino',
}

-- Resolve IDs to center objects, filtering any that don't exist in this game version
local avatar_centers = {}
for _, id in ipairs(AVATAR_JOKERS) do
	if G.P_CENTERS[id] then
		avatar_centers[#avatar_centers + 1] = G.P_CENTERS[id]
	end
end

local function clear_avatar_cards()
	for j = 1, #G.your_collection do
		for i = #G.your_collection[j].cards, 1, -1 do
			local c = G.your_collection[j]:remove_card(G.your_collection[j].cards[i])
			c:remove()
			c = nil
		end
	end
end

local function populate_page(page)
	local page_offset = CARDS_PER_PAGE * (page - 1)
	for i = 1, COLS do
		for j = 1, ROWS do
			local center = avatar_centers[i + (j - 1) * COLS + page_offset]
			if not center then
				break
			end
			local card = Card(G.your_collection[j].T.x + G.your_collection[j].T.w / 2, G.your_collection[j].T.y, G.CARD_W, G.CARD_H, nil, center, { mpapi_avatar_selectable = true })
			card.no_ui = true
			card.states.drag.can = false
			G.your_collection[j]:emplace(card)
		end
	end
end

G.FUNCS.mpapi_avatar_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	clear_avatar_cards()
	populate_page(args.cycle_config.current_option)
end

local function create_UIBox_avatar_selection()
	local deck_tables = {}

	G.your_collection = {}
	for j = 1, ROWS do
		G.your_collection[j] = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, COLS * G.CARD_W, 0.95 * G.CARD_H, { card_limit = COLS, type = 'title', highlight_limit = 0, collection = true })
		deck_tables[#deck_tables + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.07, no_fill = true },
			nodes = {
				{ n = G.UIT.O, config = { object = G.your_collection[j] } },
			},
		}
	end

	populate_page(1)

	local total_pages = math.ceil(#avatar_centers / CARDS_PER_PAGE)
	local page_options = {}
	for i = 1, total_pages do
		page_options[#page_options + 1] = localize('k_page') .. ' ' .. tostring(i) .. '/' .. tostring(total_pages)
	end

	return create_UIBox_generic_options({
		back_func = 'mpapi_back_to_account_overlay',
		contents = {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = { text = 'Choose Avatar', scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = deck_tables },
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
		},
	})
end

G.FUNCS.mpapi_open_avatar_selection = function(e)
	G.FUNCS.overlay_menu({
		definition = create_UIBox_avatar_selection(),
	})
end

G.FUNCS.mpapi_back_to_account_overlay = function(e)
	MPAPI.account_overlay:as_overlay()
end
