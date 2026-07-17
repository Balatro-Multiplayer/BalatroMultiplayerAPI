-----------------------------
-- Ban-Pick engine
-----------------------------
--
-- A generic, host-authoritative, turn-based deck draft. The host owns the canonical
-- state: it builds the candidate pool + turn order, validates every action, and
-- broadcasts the full state after each change. Guests only render the broadcast state
-- and request actions; they never mutate state locally.
--
-- Two draft shapes are supported through one engine:
--   * Legacy: `config = { pool_size, keep }` -> alternating single bans down to `keep`
--     (this is what the Speedrun mod uses; unchanged behaviour aside from random first).
--   * Scheduled: `config.schedule = { { actor=1|2, action='ban'|'pick', count=N }, ... }`
--     -> arbitrary per-turn ban counts and a final 'pick' (the picked item wins).
--
-- Pool items may be plain center KEYS ('b_red') or tables `{ key='b_red', ... }` carrying
-- metadata (e.g. a stake); `config.decorate_tile(card, item)` lets the consumer decorate
-- each tile (e.g. stamp a stake sticker). The FIRST actor is always randomized.
--
-- The two networked actions live in the *consuming* mod (a lobby only routes ActionTypes
-- whose mod.id matches -- see api/lobby.lua). The caller passes their keys via
-- config.state_action / config.ban_action; the on_receive handlers delegate straight to
-- MPAPI.BanPick.on_state / MPAPI.BanPick.apply_ban. The same ban_action message drives
-- both bans and the final pick (the host routes by the current step's action).

MPAPI.BanPick = MPAPI.BanPick or {}
local BP = MPAPI.BanPick

local _config = nil
local _on_complete = nil
local _overlay = nil
local _render = nil
local _fired = false

-- Select-and-confirm UI state: deck keys raised this turn, committed by the
-- Confirm button. Lives outside the overlay so it survives rebuilds on state
-- broadcasts (pruned against each new state instead).
local _selected = {}
local _sel_ui = { count_text = '' }
local _areas = {}

-----------------------------
-- Helpers
-----------------------------

-- Pool items are either a plain key string or a { key = ..., <meta> } table.
local function item_key(item)
	if type(item) == "table" then
		return item.key
	end
	return item
end

-- Default candidate pool: a random sample of deck Back center KEYS.
local function default_build_pool(size)
	local keys = {}
	for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
		keys[#keys + 1] = center.key
	end
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

-- Legacy schedule: `pool_size - keep` alternating single bans, no pick.
local function derive_schedule(pool_size, keep)
	local bans = math.max(0, (pool_size or 0) - (keep or 1))
	local sched = {}
	for i = 1, bans do
		sched[i] = { actor = ((i - 1) % 2) + 1, action = "ban", count = 1 }
	end
	return sched
end

-- Turn order: host first (order[1] == host, so guest ban routing via send(order[1],...)
-- is stable), then others by sorted id. `state.first` (1|2) picks which order slot is the
-- logical actor 1, so the *acting* first player is randomized independently of routing.
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

local function resolve_actor(state, actor)
	local slot = (actor == 1) and (state.first or 1) or (3 - (state.first or 1))
	return state.order[slot]
end

local function current_step(state)
	return state.schedule and state.schedule[state.sched_index]
end

local function current_actor_id(state)
	local step = current_step(state)
	return step and resolve_actor(state, step.actor)
end

local function item_for_key(state, key)
	for _, item in ipairs(state.pool) do
		if item_key(item) == key then
			return item
		end
	end
	return nil
end

-- Survivors = pool minus banned, in pool order, as ITEMS (keys or {key,meta} tables).
local function compute_survivors(state)
	local out = {}
	for _, item in ipairs(state.pool) do
		if not state.banned[item_key(item)] then
			out[#out + 1] = item
		end
	end
	return out
end

local function is_my_turn(lobby, state)
	return state and not state.complete and current_actor_id(state) == lobby.player_id
end

local function survivors_left(state)
	local n = 0
	for _, item in ipairs(state.pool) do
		if not state.banned[item_key(item)] then
			n = n + 1
		end
	end
	return n
end

-----------------------------
-- Selection (select-then-confirm)
-----------------------------

-- How many selections the current step requires. A pick step is always exactly 1;
-- a ban step wants the remaining count of the step (so a count=3 turn is one
-- three-deck selection, not three separate commits).
local function selection_needed(state)
	if not state or state.complete then
		return 0
	end
	local step = current_step(state)
	if not step then
		return 0
	end
	if step.action == "pick" then
		return 1
	end
	return state.sched_remaining or step.count or 0
end

local function selection_contains(list, key)
	for _, k in ipairs(list) do
		if k == key then
			return true
		end
	end
	return false
end

-- Toggle `key` in the selection under `cap`. Returns what happened:
-- 'removed' | 'added' | 'swapped' (cap-1 turns replace the selection, matching the
-- old single-highlight behaviour) | 'blocked' (cap full, or nothing to select).
local function selection_toggle(list, key, cap)
	for i, k in ipairs(list) do
		if k == key then
			table.remove(list, i)
			return "removed"
		end
	end
	if cap <= 0 then
		return "blocked"
	end
	if #list >= cap then
		if cap == 1 then
			list[1] = key
			return "swapped"
		end
		return "blocked"
	end
	list[#list + 1] = key
	return "added"
end

-- Drop selections invalidated by a state broadcast: keys that got banned or left
-- the pool, and anything beyond the (possibly shrunken) cap.
local function selection_prune(list, state)
	local out = {}
	local cap = selection_needed(state)
	for _, k in ipairs(list) do
		if #out < cap and item_for_key(state, k) and not state.banned[k] then
			out[#out + 1] = k
		end
	end
	return out
end

-- Exposed for the standalone test harness (dev/test_banpick_selection.lua).
BP._selection = {
	needed = selection_needed,
	contains = selection_contains,
	toggle = selection_toggle,
	prune = selection_prune,
	list = function()
		return _selected
	end,
}

-----------------------------
-- UI
-----------------------------

local PER_ROW = 9
local ROW_SCALE = 1 / 1.75

-- Passive marker attached to a selected card. Reads "Selected" (the consequence
-- lives on the Confirm button: Confirm Ban / Confirm Pick); colour still hints the
-- action (red = ban, green = pick). Purely visual -- committing happens through the
-- Confirm button, never on the card.
local function selected_tag_ui(card, action)
	local is_pick = action == "pick"
	return {
		n = G.UIT.ROOT,
		config = { padding = 0, colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.R,
				config = {
					r = 0.08,
					padding = 0.08,
					align = "bm",
					minw = 0.5 * card.T.w - 0.15,
					shadow = true,
					colour = is_pick and G.C.GREEN or G.C.MULT,
				},
				nodes = {
					{ n = G.UIT.T, config = { text = localize("k_banpick_selected_tag"), colour = G.C.UI.TEXT_LIGHT, scale = 0.35, shadow = true } },
				},
			},
		},
	}
end

local function set_card_selected(card, on, action)
	card.highlighted = on
	if on and not card.children.mp_sel_tag then
		card.children.mp_sel_tag = UIBox({
			definition = selected_tag_ui(card, action),
			config = { align = "bmi", offset = { x = 0, y = 0.4 }, parent = card },
		})
	elseif not on and card.children.mp_sel_tag then
		card.children.mp_sel_tag:remove()
		card.children.mp_sel_tag = nil
	end
end

-- Re-derive every tile's raised/tagged state and the live counter from _selected.
local function sync_selection_ui(state)
	_sel_ui.count_text = tostring(#_selected) .. '/' .. tostring(selection_needed(state))
	local step = current_step(state)
	local action = step and step.action or "ban"
	for _, area in ipairs(_areas) do
		for _, card in ipairs(area.cards or {}) do
			if card.mp_deck_key then
				set_card_selected(card, selection_contains(_selected, card.mp_deck_key), action)
			end
		end
	end
end

-- One deck tile: a card showing the deck's Back center. `item` may carry metadata; the
-- consumer's decorate_tile(card, item) is called after emplace (e.g. to stamp a stake
-- sticker via card.sticker). BANNED tiles are debuffed.
local function deck_tile(item, banned, area, decorate)
	local key = item_key(item)
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
	if decorate then
		decorate(card, item)
	end
	if banned then
		card.debuff = true
	end
	card.mp_deck_key = key

	-- Clicking toggles the mark; nothing commits here (that's the Confirm button).
	-- Off-turn and banned tiles don't react at all.
	function card:click()
		local lobby = MPAPI.get_current_lobby()
		local state = lobby and lobby._ban_pick
		if banned or not state or not is_my_turn(lobby, state) then
			return
		end
		if selection_toggle(_selected, key, selection_needed(state)) ~= "blocked" then
			sync_selection_ui(state)
		end
	end

	-- Selection drives the raise through set_card_selected; neuter the vanilla
	-- highlight (it would spawn run-context joker buttons on these tiles).
	function card:highlight(is_higlighted)
		self.highlighted = is_higlighted
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
	local step = current_step(state)
	local is_pick = step and step.action == "pick"
	local left = survivors_left(state)

	local rows = {}

	-- Title.
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_title'), scale = 0.6, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }

	-- Status: whose turn (ban vs pick) + how many actions/decks remain.
	local status_text
	if not my_turn then
		status_text = localize('k_banpick_their_turn')
	elseif is_pick then
		status_text = localize('k_banpick_pick_turn')
	else
		status_text = localize('k_banpick_your_turn')
	end
	local status_colour = my_turn and G.C.GREEN or G.C.UI.TEXT_INACTIVE
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = status_text, scale = 0.42, colour = status_colour, shadow = true } },
	} }
	local detail = is_pick
		and (localize('k_banpick_decks_left') .. ' ' .. tostring(left))
		or (localize('k_banpick_bans_left') .. ' ' .. tostring(state.sched_remaining or 0) .. '   ' .. localize('k_banpick_decks_left') .. ' ' .. tostring(left))
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = detail, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
	} }

	local decorate = _config and _config.decorate_tile
	local areas = {}
	local areas_container = {}
	local cur_area = nil
	for i, item in ipairs(state.pool) do
		if (i - 1) % PER_ROW == 0 then
			cur_area = CardArea(0, 0, G.CARD_W * ROW_SCALE * PER_ROW, G.CARD_H * ROW_SCALE, {
				type = "joker",
				highlight_limit = PER_ROW,
				card_limit = PER_ROW,
			})
			cur_area.ARGS.invisible_area_types = { joker = 1 }
			areas[#areas + 1] = cur_area
			areas_container[#areas_container + 1] = {
				n = G.UIT.R,
				config = { align = "cm" },
				nodes = {
					{ n = G.UIT.O, config = { object = cur_area } },
				},
			}
		end
		deck_tile(item, state.banned[item_key(item)], cur_area, decorate)
	end
	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.25 } }
	rows[#rows + 1] = {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.25, r = 0.25, colour = { 0, 0, 0, 0.1 } },
		nodes = areas_container,
	}

	-- Re-apply any surviving selection to the freshly built tiles (the overlay is
	-- rebuilt on every state broadcast; _selected was pruned in on_state).
	_areas = areas
	sync_selection_ui(state)

	-- Selected counter + Confirm, only on our turn. The counter text updates live
	-- via ref_table; the button enables itself per frame through the check func.
	if my_turn then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_banpick_selected') .. ' ', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'count_text', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
		} }
		-- `button` must be present at definition time: UIElement:set_values only arms
		-- states.click.can for nodes that HAVE config.button when the UIBox is built.
		-- The per-frame check then gates it by nulling config.button while not ready
		-- (the vanilla can_play pattern).
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
			{
				n = G.UIT.C,
				config = {
					align = 'cm', minw = 3.2, minh = 0.7, r = 0.1, padding = 0.08,
					shadow = true, hover = true, colour = G.C.UI.BACKGROUND_INACTIVE,
					button = 'mpapi_ban_pick_confirm', one_press = true,
					func = 'mpapi_ban_pick_confirm_check',
				},
				nodes = {
					{ n = G.UIT.T, config = { text = localize(is_pick and 'k_banpick_confirm_pick' or 'k_banpick_confirm'), scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				},
			},
		} }
	end

	return rows
end

local function build_banpick_uibox()
	return create_UIBox_generic_options({
		no_back = true,
		no_esc = true,
		contents = build_banpick_contents(),
	})
end

BP.build_contents = build_banpick_contents

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

-- Host authority: apply `from_player_id`'s action (ban or pick, per the current schedule
-- step) on `deck_key`. Returns true if it was legal and changed state (caller broadcasts).
-- Exported as apply_ban for backward compatibility with existing consumer ActionTypes.
local function apply_action(lobby, from_player_id, deck_key)
	local s = lobby._ban_pick
	if not s or s.complete then
		return false
	end
	if current_actor_id(s) ~= from_player_id then
		return false
	end
	if not item_for_key(s, deck_key) or s.banned[deck_key] then
		return false
	end

	local step = current_step(s)
	if step and step.action == "pick" then
		-- The picked item wins; everything else is discarded.
		s.survivors = { item_for_key(s, deck_key) }
		s.complete = true
		return true
	end

	-- Ban.
	s.banned[deck_key] = true
	s.sched_remaining = (s.sched_remaining or 1) - 1
	if s.sched_remaining <= 0 then
		s.sched_index = s.sched_index + 1
		local nxt = s.schedule[s.sched_index]
		if not nxt then
			s.complete = true
			s.survivors = compute_survivors(s)
		else
			s.sched_remaining = nxt.count
		end
	end
	return true
end

BP.apply_ban = apply_action

-- Called by the action button (any client). Host applies directly; guest asks the host.
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
		if apply_action(lobby, lobby.player_id, deck_key) then
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

function BP.on_state(lobby, state)
	if not state then
		return
	end
	lobby._ban_pick = state

	-- Drop marks the broadcast invalidated (opponent banned them, cap shrank).
	_selected = selection_prune(_selected, state)

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

-- Begin a draft. config = {
--   pool_size, keep,                -- legacy alternating-ban shape (if no schedule)
--   schedule,                        -- { { actor=1|2, action='ban'|'pick', count=N }, ... }
--   build_pool, decorate_tile,       -- item pool + per-tile decoration hooks
--   state_action, ban_action,        -- consumer ActionType keys
--   on_refresh,                      -- inline render callback (else self-managed overlay)
-- }. on_complete(survivors) receives the surviving items (keys or {key,meta} tables).
function BP.start(lobby, config, on_complete)
	_config = config
	_on_complete = on_complete
	_fired = false
	_selected = {}
	_areas = {}

	if lobby.is_host then
		local pool = (config.build_pool and config.build_pool()) or default_build_pool(config.pool_size)
		local schedule = config.schedule or derive_schedule(config.pool_size or #pool, config.keep or 1)
		lobby._ban_pick = {
			pool = pool,
			banned = {},
			order = build_order(lobby),
			first = math.random(2),
			schedule = schedule,
			sched_index = 1,
			sched_remaining = schedule[1] and schedule[1].count or 0,
			complete = false,
		}
		-- Degenerate schedule (nothing to do): finish immediately.
		if not schedule[1] then
			lobby._ban_pick.complete = true
			lobby._ban_pick.survivors = compute_survivors(lobby._ban_pick)
		end
	end

	_render = config.on_refresh
	_overlay = nil
	if _render then
		_render()
	else
		_overlay = MPAPI.ui_element(build_banpick_uibox)
		_overlay:as_overlay({ no_esc = true })
	end

	if lobby.is_host then
		BP.broadcast_state(lobby)
	end
end

-----------------------------
-- Button handlers
-----------------------------

-- Per-frame enable/disable for the Confirm button: live only when it's our turn
-- and the selection is exactly the size the current step requires.
G.FUNCS.mpapi_ban_pick_confirm_check = function(e)
	local lobby = MPAPI.get_current_lobby()
	local s = lobby and lobby._ban_pick
	local needed = selection_needed(s)
	if s and is_my_turn(lobby, s) and needed > 0 and #_selected == needed then
		local step = current_step(s)
		e.config.colour = (step and step.action == "pick") and G.C.GREEN or G.C.MULT
		e.config.button = "mpapi_ban_pick_confirm"
	else
		e.config.colour = G.C.UI.BACKGROUND_INACTIVE
		e.config.button = nil
	end
end

-- Commit the selection: request every marked key. Sequential requests are safe --
-- the turn stays ours until the step's count is exhausted, and the host validates
-- each one independently (see apply_action).
G.FUNCS.mpapi_ban_pick_confirm = function(_e)
	local lobby = MPAPI.get_current_lobby()
	local s = lobby and lobby._ban_pick
	if not s or not is_my_turn(lobby, s) then
		return
	end
	local needed = selection_needed(s)
	if needed == 0 or #_selected ~= needed then
		return
	end
	local keys = _selected
	_selected = {}
	for _, k in ipairs(keys) do
		BP.request_ban(k)
	end
end
