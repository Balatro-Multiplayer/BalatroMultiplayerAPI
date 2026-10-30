-----------------------------
-- Ban-Pick Draft
-----------------------------
--
-- The deck Draft's screen. The server runs the Draft as a Setup step
-- (api/setup.lua, ADR 0003): it samples the pool, rolls who acts first,
-- checks every ban and pick and bans at random for a player whose turn runs
-- out. The host only starts the step. Every client renders the tiles from the
-- server's state, sends its own bans and picks, and gets on_complete when the
-- result lands. A host change mid-Draft changes nothing.
--
-- Two Draft shapes, the same as the server's:
--   * `config = { pool_size, keep }` -> single bans rotating through every
--     player until `keep` tiles are left (`keep = 0` bans every tile; the ban
--     order is then the result).
--   * `config.schedule = { { actor = 1..N, action = 'ban' | 'pick', count }, ... }`
--     -> any ban counts per turn and a final pick (the picked tile wins).
--
-- Pool items may be plain center KEYS ('b_red') or tables `{ key = 'b_red', ... }`
-- carrying metadata (e.g. a stake); `config.decorate_tile(card, item)` decorates
-- each tile (e.g. stamps a stake sticker).

MPAPI.BanPick = MPAPI.BanPick or {}
local BP = MPAPI.BanPick
-- api/ban_pick.lua loads before api/setup.lua (the api/ scan is alphabetical), so
-- create the shared table here; setup.lua fills it in.
MPAPI.Setup = MPAPI.Setup or {}
local Setup = MPAPI.Setup

local DEFAULT_ID = "draft"
-- The server takes at most this many candidates (setup.ts MAX_CANDIDATES).
local MAX_CANDIDATES = 64

local _config = nil
-- The lobby the Draft belongs to: a Draft left unfinished in a lobby the
-- player has since left is not the next lobby's Draft. Matched by code, so a
-- rejoin of the same lobby (a new lobby object) keeps it.
local _lobby_code = nil
local _on_complete = nil
local _overlay = nil
local _render = nil
local _fired = false

-- Select-and-confirm UI state: deck keys raised this turn, committed by the
-- Confirm button. Lives outside the overlay so it survives rebuilds on Setup
-- changes (pruned against each new state instead).
local _selected = {}
local _sel_ui = { count_text = '', time_text = '' }
local _areas = {}

-----------------------------
-- Pool items
-----------------------------

-- The server tracks a tile by its `key`. An item's `id`, when present, is its
-- tracking identity instead: a pool item's *art* (its key, a real
-- G.P_CENTERS deck back) can then repeat across items that still ban and pick
-- on their own (e.g. Challenge's list, more entries than vanilla deck backs).
-- On the wire, `key` is the identity and `art` the deck back; a plain key
-- item travels as { key, plain = true }.
local function to_candidate(item)
	if type(item) ~= "table" then
		return { key = item, plain = true }
	end
	local candidate = {}
	for k, v in pairs(item) do
		candidate[k] = v
	end
	if item.id then
		candidate.key, candidate.art, candidate.id = item.id, item.key, nil
	end
	return candidate
end

local function from_candidate(candidate)
	if candidate.plain then
		return candidate.key
	end
	local item = {}
	for k, v in pairs(candidate) do
		item[k] = v
	end
	if candidate.art then
		item.id, item.key, item.art = candidate.key, candidate.art, nil
	end
	return item
end

local function art_key(candidate)
	return candidate.art or candidate.key
end

-- Default candidates: every deck Back, leaving out decks a consuming mod
-- keeps to its own matches (its isolation gate, as for every other pool).
local function default_candidates()
	local keys = {}
	for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
		if not MPAPI.should_exclude_from_pool(center) then
			keys[#keys + 1] = center.key
		end
	end
	return keys
end

local function capped_candidates(items)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = to_candidate(item)
	end
	if #out <= MAX_CANDIDATES then
		return out
	end
	for i = #out, 2, -1 do
		local j = math.random(i)
		out[i], out[j] = out[j], out[i]
	end
	for i = #out, MAX_CANDIDATES + 1, -1 do
		out[i] = nil
	end
	return out
end

-----------------------------
-- Draft state
-----------------------------

-- This screen's open Draft, as the UI reads it: { pool, banned = { key = true },
-- step, remaining, mine }; nil when it isn't open.
local function draft_view(lobby)
	local open = lobby and _config and Setup.open_step(lobby)
	if not (open and open.kind == "draft" and open.id == _config.id) then
		return nil
	end
	local banned = {}
	for _, key in ipairs(open.banned or {}) do
		banned[key] = true
	end
	return {
		pool = open.pool or {},
		banned = banned,
		step = Setup.draft_turn(lobby),
		remaining = open.remaining,
		mine = Setup.is_my_turn(lobby),
	}
end

local function item_for_key(state, key)
	for _, item in ipairs(state.pool) do
		if item.key == key then
			return item
		end
	end
	return nil
end

local function survivors_left(state)
	local n = 0
	for _, item in ipairs(state.pool) do
		if not state.banned[item.key] then
			n = n + 1
		end
	end
	return n
end

-----------------------------
-- Selection (select-then-confirm)
-----------------------------

-- How many selections the current turn requires. A pick turn is always exactly 1;
-- a ban turn wants the bans it still needs (so a count=3 turn is one
-- three-deck selection, not three separate commits).
local function selection_needed(state)
	local step = state and state.step
	if not step then
		return 0
	end
	if step.action == "pick" then
		return 1
	end
	return state.remaining or step.count or 0
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

-- Drop selections a Setup change invalidated: keys that got banned or left
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

-- Replace the whole selection with `needed` random eligible decks -- a dice press
-- is a full reroll, not a top-up, so pressing it again re-rolls. `rng` is
-- injectable for tests (defaults to math.random).
local function selection_randomize(state, rng)
	rng = rng or math.random
	local eligible = {}
	for _, item in ipairs(state.pool) do
		local k = item.key
		if not state.banned[k] then
			eligible[#eligible + 1] = k
		end
	end
	local out = {}
	local needed = selection_needed(state)
	while #out < needed and #eligible > 0 do
		out[#out + 1] = table.remove(eligible, rng(#eligible))
	end
	return out
end

-- Exposed for standalone tests of the selection rules.
BP._selection = {
	needed = selection_needed,
	contains = selection_contains,
	toggle = selection_toggle,
	prune = selection_prune,
	randomize = selection_randomize,
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
	local action = state and state.step and state.step.action or "ban"
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
	local key = item.key
	local center = G.P_CENTERS[art_key(item)]
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
		decorate(card, from_candidate(item))
	end
	if banned then
		card.debuff = true
	end
	card.mp_deck_key = key

	-- Clicking toggles the mark; nothing commits here (that's the Confirm button).
	-- Off-turn and banned tiles don't react at all.
	function card:click()
		local lobby = MPAPI.get_current_lobby()
		local state = draft_view(lobby)
		if banned or not (state and state.mine) then
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
						(self.mp_tile_note ~= nil) and {
							n = G.UIT.R,
							config = { align = "cm", padding = 0.05 },
							nodes = {
								{
									n = G.UIT.T,
									config = { text = self.mp_tile_note, scale = 0.4, colour = G.C.WHITE, shadow = true },
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
	local state = draft_view(lobby)

	if not state then
		return {
			{ n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_banpick_waiting'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
			} },
		}
	end

	local my_turn = state.mine
	local is_pick = state.step and state.step.action == "pick"
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
		or (localize('k_banpick_bans_left') .. ' ' .. tostring(state.remaining or 0) .. '   ' .. localize('k_banpick_decks_left') .. ' ' .. tostring(left))
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = detail, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
	} }
	-- The turn clock: when it runs out, the server bans (or picks) at random.
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03, func = 'mpapi_ban_pick_clock' }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_time_left') .. ' ', scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
		{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'time_text', scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
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
		deck_tile(item, state.banned[item.key], cur_area, decorate)
	end
	-- Tiles are buttons, not hand cards: never draggable (click-holding one
	-- would drag it around the panel and dismiss its hover popup mid-read;
	-- with click-to-select, a slightly-held click must still be a click).
	-- This MUST run after every emplace: CardArea:emplace -> set_ranks
	-- re-enables drag on every card already in the area, so a per-tile
	-- disable would only survive on the row's LAST tile.
	for _, area in ipairs(areas) do
		for _, card in ipairs(area.cards or {}) do
			card.states.drag.can = false
		end
	end

	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.25 } }
	rows[#rows + 1] = {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.25, r = 0.25, colour = { 0, 0, 0, 0.1 } },
		nodes = areas_container,
	}

	-- Re-apply any surviving selection to the freshly built tiles (the overlay is
	-- rebuilt on every Setup change; _selected was pruned in on_setup).
	_areas = areas
	sync_selection_ui(state)

	-- Selected counter + Confirm + Random (reroll), only on our turn. The counter
	-- text updates live via ref_table; both buttons enable themselves per frame
	-- through their check funcs.
	if my_turn then
		rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.4 } }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_banpick_selected') .. ' ', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'count_text', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
		} }
		-- `button` must be present at definition time: UIElement:set_values only arms
		-- states.click.can for nodes that HAVE config.button when the UIBox is built.
		-- The per-frame check then gates it by nulling config.button while not ready
		-- (the vanilla can_play pattern). The Random button is deliberately NOT
		-- one_press: pressing it again re-rolls.
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
			{ n = G.UIT.C, config = { minw = 0.25 } },
			{
				n = G.UIT.C,
				config = {
					align = 'cm', minw = 1.6, minh = 0.7, r = 0.1, padding = 0.08,
					shadow = true, hover = true, colour = G.C.UI.BACKGROUND_INACTIVE,
					button = 'mpapi_ban_pick_random',
					func = 'mpapi_ban_pick_random_check',
				},
				nodes = {
					{ n = G.UIT.T, config = { text = localize('k_banpick_random'), scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
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

-- True from BP.start until the Draft's result has gone to on_complete.
function BP.is_active()
	local lobby = MPAPI.get_current_lobby()
	return not _fired and _config ~= nil and lobby ~= nil and lobby.code == _lobby_code
end

-----------------------------
-- Following the server
-----------------------------

local function refresh()
	if _overlay then
		_overlay:update()
	elseif _render then
		_render()
	end
end

local function close()
	_render = nil
	if _overlay then
		_overlay = nil
		if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
			G.FUNCS.exit_overlay_menu()
		end
	end
end

local function finish(result)
	_fired = true
	local cb = _on_complete
	_on_complete = nil
	close()
	if not cb then
		-- A finished Draft with nobody to tell: the run will not start on this client.
		MPAPI.sendWarnMessage('BanPick: the Draft completed with no on_complete registered (resume not called?)')
	end
	if cb then
		local survivors = {}
		for i, candidate in ipairs(result.survivors or {}) do
			survivors[i] = from_candidate(candidate)
		end
		cb(survivors, result.banned or {})
	end
end

-- The host opens the Draft unless it is already open or done (a rejoin, a
-- restart, or a new host after the old one left before starting it).
local function open_if_host(lobby)
	if not (lobby.is_host and _config and not _fired) then
		return
	end
	local setup = Setup.state(lobby)
	if setup.open or setup.results[_config.id] then
		return
	end
	local config = _config
	local candidates = capped_candidates(
		config.candidates or (config.build_pool and config.build_pool()) or default_candidates()
	)
	local pool_size = config.pool_size and math.min(config.pool_size, #candidates) or #candidates
	Setup.start_draft(lobby, {
		id = config.id,
		candidates = candidates,
		pool_size = pool_size,
		keep = config.keep and math.min(config.keep, pool_size),
		schedule = config.schedule,
		max_stake = config.max_stake,
		turn_seconds = config.turn_seconds,
	}, function(err)
		if err and err.kind == MPAPI.ErrorKind.SERVER_TOO_OLD then
			MPAPI.sendWarnMessage(err.message)
		elseif err then
			MPAPI.sendWarnMessage("Draft start refused: " .. tostring(err.message))
		end
	end)
end

local function on_setup(setup)
	if _fired or not _config then
		return
	end
	local result = setup.results[_config.id]
	if result then
		finish(result)
		return
	end
	local lobby = MPAPI.get_current_lobby()
	_selected = selection_prune(_selected, draft_view(lobby))
	refresh()
end

local function listen(lobby)
	if lobby._ban_pick_listening then
		return
	end
	lobby._ban_pick_listening = true
	lobby:on(MPAPI.LobbyEvent.SETUP_CHANGED, on_setup)
	lobby:on(MPAPI.LobbyEvent.HOST_CHANGED, function()
		open_if_host(lobby)
	end)
	-- The game ended before the Draft did (every other player left): drop the
	-- Draft with no result, then let an inline render draw once without it.
	lobby:on(MPAPI.LobbyEvent.GAME_ENDED, function()
		if _fired or not _config or lobby.code ~= _lobby_code then
			return
		end
		local render = _render
		_config = nil
		_on_complete = nil
		close()
		if render then
			render()
		end
	end)
end

-----------------------------
-- Entry point
-----------------------------

-- Shows the Draft and, on the host, opens it on the server. Every client calls
-- this off the same game start; a rejoining client calls it again to get back
-- into a Draft already under way. config = {
--   id,                              -- the Setup step id (default 'draft')
--   pool_size, keep, schedule,       -- the Draft shape (see the file header)
--   candidates or build_pool,        -- the items the server samples the pool from
--   max_stake,                       -- the server rolls a stake 1..max per item without one
--   turn_seconds,                    -- the turn clock (server default 30)
--   decorate_tile,                   -- per-tile decoration
--   on_refresh,                      -- inline render callback (else a self-managed overlay)
-- }. on_complete(survivors, ban_order) receives the surviving items (keys or
-- tables, as given) plus the ban order (tile keys, or ids where items have
-- one): for a `keep = 0` Draft the ban order is the result.
function BP.start(lobby, config, on_complete)
	_config = setmetatable({ id = config.id or DEFAULT_ID }, { __index = config })
	_lobby_code = lobby.code
	_on_complete = on_complete
	_fired = false
	_selected = {}
	_areas = {}
	listen(lobby)

	_render = config.on_refresh
	_overlay = nil
	if _render then
		_render()
	else
		_overlay = MPAPI.ui_element(build_banpick_uibox)
		_overlay:as_overlay({ no_esc = true })
	end

	open_if_host(lobby)
	-- A restart keeps the result, and a rejoin may find the Draft under way.
	on_setup(Setup.state(lobby))
end

BP.resume = BP.start

-----------------------------
-- Button handlers
-----------------------------

G.FUNCS.mpapi_ban_pick_clock = function(_e)
	local lobby = MPAPI.get_current_lobby()
	_sel_ui.time_text = lobby and tostring(math.ceil(Setup.seconds_left(lobby))) or ''
end

-- Per-frame enable/disable for the Confirm button: live only when it's our turn
-- and the selection is exactly the size the current turn requires.
G.FUNCS.mpapi_ban_pick_confirm_check = function(e)
	local s = draft_view(MPAPI.get_current_lobby())
	local needed = selection_needed(s)
	if s and s.mine and needed > 0 and #_selected == needed then
		e.config.colour = (s.step.action == "pick") and G.C.GREEN or G.C.MULT
		e.config.button = "mpapi_ban_pick_confirm"
	else
		e.config.colour = G.C.UI.BACKGROUND_INACTIVE
		e.config.button = nil
	end
end

-- Random: replace the selection with a fresh random one (full reroll on every
-- press). Committing still goes through Confirm, so a bad roll costs nothing.
G.FUNCS.mpapi_ban_pick_random_check = function(e)
	local s = draft_view(MPAPI.get_current_lobby())
	if s and s.mine and selection_needed(s) > 0 then
		e.config.colour = G.C.BLUE
		e.config.button = "mpapi_ban_pick_random"
	else
		e.config.colour = G.C.UI.BACKGROUND_INACTIVE
		e.config.button = nil
	end
end

G.FUNCS.mpapi_ban_pick_random = function(_e)
	local s = draft_view(MPAPI.get_current_lobby())
	if not (s and s.mine) then
		return
	end
	local out = selection_randomize(s)
	if #out == 0 then
		return
	end
	_selected = out
	sync_selection_ui(s)
end

-- Commit the selection: one choose per marked key, in order. The turn stays
-- ours until its bans are all in, and the server checks each one.
G.FUNCS.mpapi_ban_pick_confirm = function(_e)
	local lobby = MPAPI.get_current_lobby()
	local s = draft_view(lobby)
	if not (s and s.mine) then
		return
	end
	local needed = selection_needed(s)
	if needed == 0 or #_selected ~= needed then
		return
	end
	local keys = _selected
	_selected = {}
	for _, k in ipairs(keys) do
		Setup.choose(lobby, k)
	end
end
