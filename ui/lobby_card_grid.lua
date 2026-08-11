-- Instanced lobby player-card grid: pagination, roster sync, and the card
-- pool itself. Factored out of a former module-level singleton (see git
-- history of ui/lobby.lua) so the live lobby view and the Lobby Info
-- overlay's Players tab (ui/lobby_info_overlay.lua) can each run their own
-- independent grid against the same lobby without clobbering each other's
-- card/page state -- closing the overlay must hand control back to the live
-- view's own untouched cards, not whatever the overlay last built.
local COLS = 4
local ROWS_PER_PAGE = 4
local SLOTS_PER_PAGE = COLS * ROWS_PER_PAGE

-- Every live grid instance, so Card:click/Card:hover overrides (ui/lobby.lua)
-- can find which grid owns a given card regardless of how many are open.
local _active_grids = {}
local _next_instance_id = 0

local function make_card(card_area, joker_key, face_down)
	local center = G.P_CENTERS[joker_key] or G.P_CENTERS['j_joker']
	local card = Card(card_area.T.x + card_area.T.w / 2, card_area.T.y, G.CARD_W, G.CARD_H, nil, center, { mpapi_lobby_card = true, bypass_back = G.P_CENTERS['b_black'].pos })
	card.no_ui = true
	card.states.drag.can = false

	if face_down then
		card:flip()
	end

	return card
end

MPAPI._new_card_grid = function()
	_next_instance_id = _next_instance_id + 1

	local grid = {
		_instance_id = _next_instance_id,
		_card_rows = {},
		_row_nodes = {},
		_cards = {},
		_player_card_map = {}, -- playerId -> card index (global across all slots)
		_max_players = 16,
		_current_page = 1,
		_page_cycle_func_name = nil,
		lobby = nil,
	}

	function grid:get_row_for_slot(slot)
		local page_offset = SLOTS_PER_PAGE * (self._current_page - 1)
		local local_slot = slot - page_offset
		if local_slot < 1 or local_slot > SLOTS_PER_PAGE then
			return nil
		end
		local row_idx = math.ceil(local_slot / COLS)
		return self._card_rows[row_idx]
	end

	function grid:find_empty_slot()
		for i, card in ipairs(self._cards) do
			if card and card.facing == 'back' then
				return i
			end
		end
		return nil
	end

	function grid:find_card_for_player(player_id)
		local idx = self._player_card_map[player_id]
		if idx and self._cards[idx] then
			return idx
		end
		return nil
	end

	function grid:create_card_rows(player_count)
		self._card_rows = {}
		self._row_nodes = {}
		local rows_needed = math.max(1, math.min(ROWS_PER_PAGE, math.ceil(player_count / COLS)))
		for j = 1, rows_needed do
			local cols_in_row = math.min(COLS, self._max_players - (j - 1) * COLS)
			if cols_in_row < 1 then
				break
			end
			-- card_limit must match cols_in_row (not the constant COLS), since
			-- CardArea's 'title' layout centers cards using
			-- max(#self.cards, self.config.temp_limit) as the slot count it
			-- divides the area's width by (cardarea.lua's align_cards) --
			-- temp_limit defaults to card_limit at construction and this area
			-- never grows past its row's real card count. A row with fewer
			-- than COLS cards (any row but a completely full one) but a
			-- hardcoded card_limit=COLS had its cards positioned as if
			-- centered in a COLS-wide area while actually occupying a
			-- cols_in_row-wide one, visibly off-center.
			self._card_rows[j] = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, cols_in_row * G.CARD_W, 0.95 * G.CARD_H, { card_limit = cols_in_row, type = 'title', highlight_limit = 0, collection = true })
			self._row_nodes[#self._row_nodes + 1] = {
				n = G.UIT.R,
				config = { align = 'cm', padding = 0.07, no_fill = true },
				nodes = {
					{ n = G.UIT.O, config = { object = self._card_rows[j] } },
				},
			}
		end
	end

	function grid:clear_page_cards()
		for j = 1, #self._card_rows do
			for i = #self._card_rows[j].cards, 1, -1 do
				local c = self._card_rows[j]:remove_card(self._card_rows[j].cards[i])
				c:remove()
				c = nil
			end
		end
	end

	function grid:populate_page(page, lobby)
		self._current_page = page
		local page_offset = SLOTS_PER_PAGE * (page - 1)

		local assigned = {}
		for pid, slot in pairs(self._player_card_map) do
			assigned[slot] = pid
		end

		for i = 1, SLOTS_PER_PAGE do
			local global_slot = page_offset + i
			if global_slot > self._max_players then
				break
			end

			local row_idx = math.ceil(i / COLS)
			local card_area = self._card_rows[row_idx]
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
			if player_data then
				card:set_debuff(MPAPI._is_player_debuffed(lobby, player_data))
			end
			self._cards[global_slot] = card
		end
	end

	function grid:create_lobby_cards(lobby)
		self._cards = {}
		self._player_card_map = {}

		local players = lobby:get_players()

		for i, p in ipairs(players) do
			if i > self._max_players then
				break
			end
			self._player_card_map[p.id] = i
		end

		self:populate_page(1, lobby)
	end

	function grid:build_lobby_nodes(lobby)
		self.lobby = lobby
		self._player_card_map = {}
		self._max_players = lobby.max_players or 16

		local players = lobby:get_players()
		self:create_card_rows(math.max(1, #players))
		self:create_lobby_cards(lobby)

		local total_pages = math.ceil(self._max_players / SLOTS_PER_PAGE)
		local page_options = {}
		for i = 1, total_pages do
			page_options[#page_options + 1] = localize('k_page') .. ' ' .. tostring(i) .. '/' .. tostring(total_pages)
		end

		local nodes = {
			{ n = G.UIT.R, config = { align = 'cm', r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = self._row_nodes },
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
						opt_callback = self._page_cycle_func_name,
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

	-- Builds the reactive element for this grid against `lobby`. Each instance
	-- gets its own page-cycle G.FUNCS callback name (rather than one shared
	-- global) so two concurrently-open grids never fight over whose page is
	-- "current".
	function grid:build_element(lobby)
		self._page_cycle_func_name = 'mpapi_lobby_page_' .. self._instance_id
		G.FUNCS[self._page_cycle_func_name] = function(args)
			if not args or not args.cycle_config then
				return
			end
			if not self.lobby then
				return
			end
			self:clear_page_cards()
			self:populate_page(args.cycle_config.current_option, self.lobby)
		end

		local build_fn = function()
			return self:build_lobby_nodes(lobby)
		end

		local el = MPAPI.ui_element(build_fn)
		self.el = el

		lobby:on(MPAPI.LobbyEvent.PLAYER_INFO, function(player_id, player_data)
			if not self._card_rows or #self._card_rows == 0 then
				return
			end

			local joker_key = player_data.preferredJoker or 'j_joker'
			local center = G.P_CENTERS[joker_key] or G.P_CENTERS['j_joker']

			local existing_idx = self:find_card_for_player(player_id)
			if existing_idx then
				local card = self._cards[existing_idx]
				if card and self:get_row_for_slot(existing_idx) then
					card:set_ability(center)
					card:set_debuff(MPAPI._is_player_debuffed(lobby, player_data))
					card:juice_up(0.3, 0.3)
				end
				return
			end

			local slot = self:find_empty_slot()
			if not slot then
				self:clear_page_cards()
				self._card_rows = {}
				self._cards = {}
				el:update()
				return
			end

			self._player_card_map[player_id] = slot
			local card = self._cards[slot]

			if not card or not self:get_row_for_slot(slot) then
				return
			end

			card:set_ability(center)
			card:set_debuff(MPAPI._is_player_debuffed(lobby, player_data))

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
			local idx = self:find_card_for_player(player_id)
			if not idx or not self._cards[idx] then
				self._player_card_map[player_id] = nil
				return
			end

			self._player_card_map[player_id] = nil

			local card = self._cards[idx]
			if not card or not self:get_row_for_slot(idx) then
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

	function grid:contains_card(card)
		for _, c in ipairs(self._cards) do
			if c == card then
				return true
			end
		end
		return false
	end

	function grid:get_player_for_card(card)
		if not self.lobby then
			return nil
		end
		for pid, slot in pairs(self._player_card_map) do
			if self._cards[slot] == card then
				return self.lobby._players[pid]
			end
		end
		return nil
	end

	-- Unregisters this grid so Card:click/Card:hover stop routing to it, and
	-- frees its page-cycle G.FUNCS entry. Does not remove already-placed Card
	-- objects from the screen -- callers (e.g. the overlay closing) are
	-- responsible for that via clear_page_cards() first if needed.
	function grid:destroy()
		for i, g in ipairs(_active_grids) do
			if g == self then
				table.remove(_active_grids, i)
				break
			end
		end
		if self._page_cycle_func_name then
			G.FUNCS[self._page_cycle_func_name] = nil
			self._page_cycle_func_name = nil
		end
		-- Release card/player references too (not just deregister) so a stray
		-- direct reference to a destroyed grid can't report stale ownership.
		self._cards = {}
		self._player_card_map = {}
		self.lobby = nil
	end

	_active_grids[#_active_grids + 1] = grid
	return grid
end

-- Exposed for ui/lobby.lua's Card:click/Card:hover overrides.
MPAPI._active_card_grids = _active_grids
