-----------------------------
-- Ban-Pick engine
-----------------------------
--
-- A generic, host-authoritative, turn-based ban draft over a list of P_CENTER keys
-- (here: deck "Back" centers, but nothing below is deck-specific). The host owns the
-- canonical state: it generates the random candidate pool and the turn order, validates
-- every ban, and broadcasts the full state after each change. Guests only render the
-- broadcast state and request bans; they never mutate state locally.
--
-- The two networked actions live in the *consuming* mod (a lobby only routes ActionTypes
-- whose mod.id matches the lobby's mod -- see api/lobby.lua). The caller passes their keys
-- in via config.state_action / config.ban_action; the on_receive handlers there delegate
-- straight back to MPAPI.BanPick.on_state / MPAPI.BanPick.apply_ban.
--
-- Flow (every client runs BanPick.start from the same synced trigger):
--   host  : build pool + order -> store state -> open overlay -> broadcast state
--   guest : open overlay (renders once the host's state arrives) and wait
--   ...players alternate banning; each ban -> host applies -> host broadcasts new state...
--   done  : state.complete = true, state.survivors set -> overlay closes -> on_complete(survivors)

MPAPI.BanPick = MPAPI.BanPick or {}
local BP = MPAPI.BanPick

-- Only one draft is active at a time (one lobby, one run start), so the session-scoped
-- handles live as module locals rather than on the lobby.
local _config = nil
local _on_complete = nil
local _overlay = nil
-- Set when a consumer renders the draft inline (config.on_refresh); mutually exclusive with _overlay.
local _render = nil
local _fired = false

-----------------------------
-- Helpers
-----------------------------

-- Default candidate pool: a random sample of deck Back centers. The profile system
-- guarantees no locked decks are present in a lobby, so no filtering is needed.
local function default_build_pool(size)
	local keys = {}
	for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
		keys[#keys + 1] = center.key
	end
	-- Fisher-Yates shuffle, then take the first `size`.
	for i = #keys, 2, -1 do
		local j = math.random(i)
		keys[i], keys[j] = keys[j], keys[i]
	end
	local pool = {}
	for i = 1, math.min(size, #keys) do
		pool[i] = keys[i]
	end
	return pool
end

-- Turn order: host first, then the other players by sorted id (deterministic; only the
-- host builds this, but a stable order keeps it predictable across re-reads).
local function build_order(lobby)
	local order = { lobby.player_id }
	local others = {}
	for _, p in ipairs(lobby:get_players()) do
		if p.id ~= lobby.player_id then
			others[#others + 1] = p.id
		end
	end
	table.sort(others)
	for _, id in ipairs(others) do
		order[#order + 1] = id
	end
	return order
end

-- Survivors = pool minus banned, in pool order, as center KEYS (e.g. 'b_red'). The deck
-- is applied at run start via G.GAME.viewed_back = G.P_CENTERS[key] (the proven pattern;
-- the consumer resolves these keys).
local function compute_survivors(state)
	local keys = {}
	for _, key in ipairs(state.pool) do
		if not state.banned[key] then
			keys[#keys + 1] = key
		end
	end
	return keys
end

local function is_my_turn(lobby, state)
	return state and not state.complete and state.order[state.turn_index] == lobby.player_id
end

-----------------------------
-- UI
-----------------------------

local PER_ROW = 9
local ROW_SCALE = 1 / 1.75

local function deck_action_buttons(card, key, banned, my_turn)
	local text, colour, button
	if banned then
		colour = G.C.UI.BACKGROUND_INACTIVE
		text = localize("k_banpick_banned")
	elseif my_turn then
		colour = G.C.MULT
		text = localize("k_banpick_ban")
		button = "mpapi_ban_pick_ban"
	else
		colour = G.C.UI.BACKGROUND_INACTIVE
		text = localize("k_banpick_ban")
	end
	return {
		n = G.UIT.ROOT,
		config = { padding = 0, colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.R,
				config = {
					ref_table = { deck_key = key },
					r = 0.08,
					padding = 0.1,
					align = "bm",
					minw = 0.5 * card.T.w - 0.15,
					maxw = 0.9 * card.T.w - 0.15,
					minh = 1 * card.T.h, hover = true, shadow = true, colour = colour, one_press = true, button = button,
				},
				nodes = {
					{ n = G.UIT.T, config = { text = text, colour = G.C.UI.TEXT_LIGHT, scale = 0.45, shadow = true } },
				},
			},
		},
	}
end

-- One deck tile: a card with deck's center
-- BANNED marked as debuffed
local function deck_tile(key, banned, my_turn, area)
	local center = G.P_CENTERS[key]
	local card = Card(
		area.T.x + area.T.w / 2,
		area.T.y,
		G.CARD_W * ROW_SCALE,
		G.CARD_H * ROW_SCALE,
		nil,
		center,
		{ bypass_discovery_center = true }
	)
	area:emplace(card)
	if banned then
		card.debuff = true
	end

	function card:highlight(is_higlighted)
		if is_higlighted then
			for _, _area in ipairs(self.area.mp_ban_areas) do
				if _area ~= area then
					_area:unhighlight_all()
				end
			end
		end
		self.highlighted = is_higlighted
		if self.highlighted and self.area then
            if self.children.use_button then self.children.use_button:remove() end
			self.children.use_button = UIBox({
				definition = deck_action_buttons(self, key, banned, my_turn),
				config = {
					align = "bmi",
					offset = { x = 0, y = 0.55 },
					parent = self,
				},
			})
		elseif self.children.use_button then
			self.children.use_button:remove()
			self.children.use_button = nil
		end
	end

	function card:hover()
		local back = Back(self.config.center)

		local badges = { n = G.UIT.C, config = { colour = G.C.CLEAR, align = "cm" }, nodes = {} }
		SMODS.create_mod_badges(self.config.center, badges.nodes)
		if badges.nodes.mod_set then
			badges.nodes.mod_set = nil
		end

		self.config.h_popup = { n = G.UIT.C, config = { align = "cm", padding = 0.1 }, nodes = {} }

		table.insert(self.config.h_popup.nodes, (self.T.x > G.ROOM.T.w * 0.4) and 2 or 1, {
			n = G.UIT.C,
			config = { align = "cm", padding = 0.1 },
			nodes = {
				{
					n = G.UIT.C,
					config = { align = "cm", r = 0.1, colour = G.C.L_BLACK, padding = 0.1, outline = 1 },
					nodes = {
						{
							n = G.UIT.R,
							config = { align = "cm", r = 0.1, minw = 3, maxw = 4, minh = 0.4 },
							nodes = {
								{
									n = G.UIT.O,
									config = {
										object = DynaText({
											string = back:get_name(),
											maxw = 4,
											colours = { G.C.WHITE }, shadow = true, bump = true, scale = 0.5, pop_in = 0, silent = true,
										}),
									},
								},
							},
						},
						{
							n = G.UIT.R,
							config = {
								align = "cm",
								colour = G.C.WHITE, minh = 0.5, maxh = 3, minw = 3, maxw = 4, r = 0.1,
							},
							nodes = {
								{
									n = G.UIT.O,
									config = {
										object = UIBox({
											definition = back:generate_UI(),
											config = { offset = { x = 0, y = 0 } },
										}),
									},
								},
							},
						},
						badges.nodes[1] and {
							n = G.UIT.R,
							config = { align = "cm", r = 0.1, minw = 3, maxw = 4, minh = 0.4 },
							nodes = { badges },
						},
					},
				},
			},
		})

		self.config.h_popup_config = self:align_h_popup()
		Node.hover(self)
	end
end

local function build_banpick_contents()
	local lobby = MPAPI.get_current_lobby()
	local state = lobby and lobby._ban_pick

	if not state or not state.pool then
		return {
			{ n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_banpick_waiting'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
			} },
		}
	end

	local my_turn = is_my_turn(lobby, state)
	local survivors_left = #state.pool
	for _ in pairs(state.banned) do
		survivors_left = survivors_left - 1
	end

	local rows = {}

	-- Title.
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_title'), scale = 0.6, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }

	-- Status: whose turn + how many bans / decks remain.
	local status_text = my_turn and localize('k_banpick_your_turn') or localize('k_banpick_their_turn')
	local status_colour = my_turn and G.C.GREEN or G.C.UI.TEXT_INACTIVE
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = status_text, scale = 0.42, colour = status_colour, shadow = true } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_bans_left') .. ' ' .. tostring(state.bans_remaining) .. '   ' .. localize('k_banpick_decks_left') .. ' ' .. tostring(survivors_left) .. ' / ' .. tostring(state.keep), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
	} }

    local areas = {}
    local areas_container = {}
	-- Deck grid, PER_ROW tiles per row.
	local cur_area = nil
	for i, key in ipairs(state.pool) do
		if (i - 1) % PER_ROW == 0 then
            -- Create area for decks
            cur_area = CardArea(0, 0, G.CARD_W * ROW_SCALE * PER_ROW, G.CARD_H * ROW_SCALE, {
                type = "joker",
                highlight_limit = 1,
                card_limit = PER_ROW,
            })
            -- Hide cards/limit display
            cur_area.ARGS.invisible_area_types = { joker = 1 }
            areas[#areas + 1] = cur_area
            -- Store all areas so when one card is selected, all others are deselected
            cur_area.mp_ban_areas = areas
            areas_container[#areas_container + 1] = {
                n = G.UIT.R,
                config = { align = "cm" },
                nodes = {
                    { n = G.UIT.O, config = { object = cur_area } },
                },
            }
		end
		deck_tile(key, state.banned[key], my_turn, cur_area)
	end
    rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.25 } }
    rows[#rows + 1] = {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.25, r = 0.25, colour = { 0, 0, 0, 0.1 } },
        nodes = areas_container,
    }

	return rows
end

local function build_banpick_uibox()
	return create_UIBox_generic_options({
		no_back = true,
		no_esc = true,
		contents = build_banpick_contents(),
	})
end

-- The draft's UI rows for the current lobby, for a consumer rendering it inline.
BP.build_contents = build_banpick_contents

-- True while a draft is in progress (started, not yet completed) for the current lobby.
function BP.is_active()
	if _fired or not _config then
		return false
	end
	local lobby = MPAPI.get_current_lobby()
	return lobby ~= nil and lobby._ban_pick ~= nil
end

-----------------------------
-- Networking
-----------------------------

-- Host: publish the full canonical state to everyone (the host's own copy arrives back via
-- the broadcast loopback, so the same on_state render path runs on every client).
function BP.broadcast_state(lobby)
	if not _config then
		return
	end
	local action_type = MPAPI.ActionTypes[_config.state_action]
	if not action_type then
		return
	end
	lobby:action(action_type):broadcast({ state = lobby._ban_pick })
end

-- Host authority: apply `from_player_id`'s ban of `deck_key`. Returns true if it was a
-- legal ban that changed state (so the caller knows to broadcast).
function BP.apply_ban(lobby, from_player_id, deck_key)
	local s = lobby._ban_pick
	if not s or s.complete then
		return false
	end
	-- Must be this player's turn.
	if s.order[s.turn_index] ~= from_player_id then
		return false
	end
	-- Deck must be in the pool and not already banned.
	local in_pool = false
	for _, k in ipairs(s.pool) do
		if k == deck_key then
			in_pool = true
			break
		end
	end
	if not in_pool or s.banned[deck_key] then
		return false
	end

	s.banned[deck_key] = true
	s.bans_remaining = s.bans_remaining - 1
	if s.bans_remaining <= 0 then
		s.complete = true
		s.survivors = compute_survivors(s)
	else
		-- Advance to the next player in the rotation.
		s.turn_index = (s.turn_index % #s.order) + 1
	end
	return true
end

-- Called by the Ban button (any client). Host applies directly; guest asks the host.
function BP.request_ban(deck_key)
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		return
	end
	local s = lobby._ban_pick
	if not is_my_turn(lobby, s) then
		return
	end

	if lobby.is_host then
		if BP.apply_ban(lobby, lobby.player_id, deck_key) then
			BP.broadcast_state(lobby)
			if _overlay then
				_overlay:update()
			elseif _render then
				_render()
			end
		end
	else
		local action_type = MPAPI.ActionTypes[_config.ban_action]
		if action_type then
			-- order[1] is the host.
			lobby:action(action_type):send(s.order[1], { item_key = deck_key })
		end
	end
end

-- Every client: adopt the host's broadcast state, refresh the overlay, and on completion
-- close it and fire on_complete(survivors) exactly once.
function BP.on_state(lobby, state)
	if not state then
		return
	end
	lobby._ban_pick = state

	if _overlay then
		_overlay:update()
	elseif _render then
		_render()
	end

	if state.complete and not _fired then
		_fired = true
		local cb = _on_complete
		_on_complete = nil
		if _overlay then
			_overlay = nil
			if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
				G.FUNCS.exit_overlay_menu()
			end
		end
		_render = nil
		if cb then
			cb(state.survivors or {})
		end
	end
end

-----------------------------
-- Entry point
-----------------------------

-- Begin a draft. config = { pool_size, keep, state_action, ban_action, build_pool? }.
-- on_complete(survivors) receives the surviving deck names, in pool order.
function BP.start(lobby, config, on_complete)
	_config = config
	_on_complete = on_complete
	_fired = false

	if lobby.is_host then
		local pool = (config.build_pool and config.build_pool()) or default_build_pool(config.pool_size)
		lobby._ban_pick = {
			pool = pool,
			banned = {},
			order = build_order(lobby),
			turn_index = 1,
			bans_remaining = math.max(0, #pool - config.keep),
			keep = config.keep,
			complete = false,
		}
		-- Degenerate config (nothing to ban): finish immediately.
		if lobby._ban_pick.bans_remaining <= 0 then
			lobby._ban_pick.complete = true
			lobby._ban_pick.survivors = compute_survivors(lobby._ban_pick)
		end
	end

	-- Render inline when the consumer supplies a refresh callback, else use the self-managed
	-- overlay. no_esc so the mandatory turn-based draft cannot be closed mid-flight.
	_render = config.on_refresh
	_overlay = nil
	if _render then
		_render()
	else
		_overlay = MPAPI.ui_element(build_banpick_uibox)
		_overlay:as_overlay({ no_esc = true })
	end

	if lobby.is_host then
		-- The loopback delivery of this broadcast drives on_state (UI refresh, and the
		-- completion path if the draft is already done).
		BP.broadcast_state(lobby)
	end
end

-----------------------------
-- Button handler
-----------------------------

G.FUNCS.mpapi_ban_pick_ban = function(e)
	local key = e and e.config and e.config.ref_table and e.config.ref_table.deck_key
	if key then
		MPAPI.BanPick.request_ban(key)
	end
end
