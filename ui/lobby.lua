-- Forward declarations for helper functions
local create_card_rows
local create_lobby_cards
local populate_page
local clear_page_cards
local find_empty_slot
local find_card_for_player
local make_card
local get_row_for_slot
local get_player_for_card
local lobby_card_click_override
local lobby_card_hover_override

-----------------------------
-- CONSTANTS
-----------------------------

local COLS = 4
local ROWS_PER_PAGE = 4
local SLOTS_PER_PAGE = COLS * ROWS_PER_PAGE

-----------------------------
-- STATE VARIABLES
-----------------------------

local _card_rows = {}
local _row_nodes = {}
local _cards = {}
local _player_card_map = {} -- playerId -> card index (global across all slots)
local _current_lobby_ref = nil
local _max_players = 16
local _current_page = 1

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

get_row_for_slot = function(slot)
	local page_offset = SLOTS_PER_PAGE * (_current_page - 1)
	local local_slot = slot - page_offset
	if local_slot < 1 or local_slot > SLOTS_PER_PAGE then
		return nil
	end
	local row_idx = math.ceil(local_slot / COLS)
	return _card_rows[row_idx]
end

make_card = function(card_area, joker_key, face_down)
	local center = G.P_CENTERS[joker_key] or G.P_CENTERS['j_joker']
	local card = Card(card_area.T.x + card_area.T.w / 2, card_area.T.y, G.CARD_W, G.CARD_H, nil, center, { mpapi_lobby_card = true, bypass_back = G.P_CENTERS['b_black'].pos })
	card.no_ui = true
	card.states.drag.can = false

	if face_down then
		card:flip()
	end

	return card
end

find_empty_slot = function()
	for i, card in ipairs(_cards) do
		if card and card.facing == 'back' then
			return i
		end
	end
	return nil
end

find_card_for_player = function(player_id)
	local idx = _player_card_map[player_id]
	if idx and _cards[idx] then
		return idx
	end
	return nil
end

-----------------------------
-- UI BUILD FUNCTIONS
-----------------------------

create_card_rows = function(player_count)
	_card_rows = {}
	_row_nodes = {}
	local rows_needed = math.max(1, math.min(ROWS_PER_PAGE, math.ceil(player_count / COLS)))
	for j = 1, rows_needed do
		local cols_in_row = math.min(COLS, _max_players - (j - 1) * COLS)
		if cols_in_row < 1 then
			break
		end
		_card_rows[j] = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, cols_in_row * G.CARD_W, 0.95 * G.CARD_H, { card_limit = COLS, type = 'title', highlight_limit = 0, collection = true })
		_row_nodes[#_row_nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.07, no_fill = true },
			nodes = {
				{ n = G.UIT.O, config = { object = _card_rows[j] } },
			},
		}
	end
end

clear_page_cards = function()
	for j = 1, #_card_rows do
		for i = #_card_rows[j].cards, 1, -1 do
			local c = _card_rows[j]:remove_card(_card_rows[j].cards[i])
			c:remove()
			c = nil
		end
	end
end

populate_page = function(page, lobby)
	_current_page = page
	local page_offset = SLOTS_PER_PAGE * (page - 1)

	local assigned = {}
	for pid, slot in pairs(_player_card_map) do
		assigned[slot] = pid
	end

	for i = 1, SLOTS_PER_PAGE do
		local global_slot = page_offset + i
		if global_slot > _max_players then
			break
		end

		local row_idx = math.ceil(i / COLS)
		local card_area = _card_rows[row_idx]
		if not card_area then
			break
		end

		local pid = assigned[global_slot]
		local player_data = nil
		if pid then
			player_data = lobby._players[pid]
		end

		local joker_key = 'j_joker'
		local is_empty = true

		if player_data and player_data.preferredJoker then
			joker_key = player_data.preferredJoker
			is_empty = false
		end

		local card = make_card(card_area, joker_key, is_empty)
		card_area:emplace(card, nil, is_empty)
		_cards[global_slot] = card
	end
end

create_lobby_cards = function(lobby)
	_cards = {}
	_player_card_map = {}

	local players = lobby:get_players()

	for i, p in ipairs(players) do
		if i > _max_players then
			break
		end
		_player_card_map[p.id] = i
	end

	populate_page(1, lobby)
end

local build_lobby_nodes = function(lobby)
	_current_lobby_ref = lobby
	_player_card_map = {}
	_max_players = lobby.max_players or 16

	local players = lobby:get_players()
	create_card_rows(math.max(1, #players))
	create_lobby_cards(lobby)

	local code_text = lobby.code or '...'

	local total_pages = math.ceil(_max_players / SLOTS_PER_PAGE)
	local page_options = {}
	for i = 1, total_pages do
		page_options[#page_options + 1] = localize('k_page') .. ' ' .. tostring(i) .. '/' .. tostring(total_pages)
	end

	local nodes = {
		{ n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = _row_nodes },
	}

	if total_pages > 1 then
		nodes[#nodes + 1] = {
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				create_option_cycle({
					options = page_options,
					w = 4.5,
					cycle_shoulders = true,
					opt_callback = 'mpapi_lobby_page',
					current_option = 1,
					colour = MPAPI.C.MP_EDITION,
					no_pips = true,
					focus_args = { snap_to = true, nav = 'wide' },
				}),
			},
		}
	end

	return {
		n = G.UIT.ROOT,
		config = { align = 'cm', colour = G.C.CLEAR },
		nodes = nodes,
	}
end

-----------------------------
-- API FUNCTIONS
-----------------------------

MPAPI.create_lobby_ui = function(lobby)
	local build_fn = function()
		return build_lobby_nodes(lobby)
	end

	local el = MPAPI.ui_element(build_fn)

	lobby:on(MPAPI.LobbyEvent.PLAYER_INFO, function(player_id, player_data)
		if not _card_rows or #_card_rows == 0 then
			return
		end

		local joker_key = player_data.preferredJoker or 'j_joker'
		local center = G.P_CENTERS[joker_key] or G.P_CENTERS['j_joker']

		local existing_idx = find_card_for_player(player_id)
		if existing_idx then
			local card = _cards[existing_idx]
			if card and get_row_for_slot(existing_idx) then
				card:set_ability(center)
				card:juice_up(0.3, 0.3)
			end
			return
		end

		local slot = find_empty_slot()
		if not slot then
			clear_page_cards()
			_card_rows = {}
			_cards = {}
			el:update()
			return
		end

		_player_card_map[player_id] = slot
		local card = _cards[slot]

		if not card or not get_row_for_slot(slot) then
			return
		end

		card:set_ability(center)

		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = 0.15,
			func = function()
				card:flip()
				play_sound('card1')
				card:juice_up(0.3, 0.3)
				return true
			end,
		}))
	end)

	lobby:on(MPAPI.LobbyEvent.PLAYER_LEFT, function(player_id)
		local idx = find_card_for_player(player_id)
		if not idx or not _cards[idx] then
			_player_card_map[player_id] = nil
			return
		end

		_player_card_map[player_id] = nil

		local card = _cards[idx]
		if not card or not get_row_for_slot(idx) then
			return
		end

		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = 0.15,
			func = function()
				card:flip()
				play_sound('card1')
				return true
			end,
		}))

		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = 0.3,
			func = function()
				local joker_center = G.P_CENTERS['j_joker']
				card:set_ability(joker_center)
				return true
			end,
		}))
	end)

	return el
end

-----------------------------
-- PAGE CYCLING
-----------------------------

G.FUNCS.mpapi_lobby_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	if not _current_lobby_ref then
		return
	end
	clear_page_cards()
	populate_page(args.cycle_config.current_option, _current_lobby_ref)
end

-----------------------------
-- OVERRIDES
-----------------------------

get_player_for_card = function(card)
	if not _current_lobby_ref then
		return nil
	end
	for pid, slot in pairs(_player_card_map) do
		if _cards[slot] == card then
			return _current_lobby_ref._players[pid]
		end
	end
	return nil
end

lobby_card_click_override = function(self)
	if self.params.mpapi_lobby_card then
		return true
	end
end

lobby_card_hover_override = function(self)
	if not self.params.mpapi_lobby_card then
		return false
	end

	if self.facing ~= 'front' then
		return true
	end

	self:juice_up(0.05, 0.03)
	play_sound('paper1', math.random() * 0.2 + 0.9, 0.35)

	local player_data = get_player_for_card(self)
	if not player_data then
		return true
	end

	local display_name = player_data.displayName or 'Unknown'

	local badge = create_badge('Player', MPAPI.C.MP_EDITION, G.C.WHITE, 1.2)

	self.ability_UIBox_table = {
		card_type = 'Joker',
		name = {
			{ n = G.UIT.O, config = {
				object = DynaText({
					string = { display_name },
					colours = { G.C.WHITE },
					float = true,
					shadow = true,
					scale = 0.45,
					silent = true,
				}),
			} },
		},
		main = {},
		badges = {},
		info = {},
	}

	-- Build popup manually to avoid rarity badge logic
	local card_type_background = darken(G.C.BLACK, 0.1)
	self.config.h_popup = {
		n = G.UIT.ROOT,
		config = { align = 'cm', colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm' },
				nodes = {
					{
						n = G.UIT.R,
						config = { padding = 0.05, r = 0.12, colour = lighten(G.C.JOKER_GREY, 0.5), emboss = 0.07 },
						nodes = {
							{
								n = G.UIT.R,
								config = { align = 'cm', padding = 0.07, r = 0.1, colour = adjust_alpha(card_type_background, 0.8) },
								nodes = {
									name_from_rows(self.ability_UIBox_table.name),
									{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = { badge } },
								},
							},
						},
					},
				},
			},
		},
	}
	self.config.h_popup_config = self:align_h_popup()
	Node.hover(self)

	return true
end

local _card_click_ref = Card.click
function Card:click()
	if lobby_card_click_override(self) then
		return
	end
	_card_click_ref(self)
end

local _card_hover_ref = Card.hover
function Card:hover()
	if lobby_card_hover_override(self) then
		return
	end
	_card_hover_ref(self)
end
