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

-- Select-and-confirm UI state: item ids raised this turn, committed by the
-- Confirm button. Lives outside the overlay so it survives rebuilds on state
-- broadcasts (pruned against each new state instead).
local _selected = {}
local _sel_ui = { count_text = '', confirm_text = '', random_text = '' }
local _areas = {}
-- Blind-random mode: arming Random commits you to unseen picks -- nothing is
-- marked or revealed, and the actual roll happens only when Confirm is pressed
-- (so there is nothing to peek at or reroll-fish for).
local _random_armed = false

-- Per-draft identity guard: the host stamps each draft with a unique draft_id
-- carried ON the state. on_state drops a state from a dead (completed or
-- superseded) draft; a new draft_id supersedes the old one. No draft_id
-- (older host) = accept. State is a full snapshot, so a duplicate just
-- re-applies harmlessly -- no per-message sequencing (consistent with every
-- other synced state).
local _current_draft_id = nil
local _dead_drafts = {}
local _draft_counter = 0

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

-- Unique identity of a pool item WITHIN its pool. Tuple pools may repeat a deck at
-- different stakes (up to 3), so identity must be key+stake, not key -- banning
-- Red@White must not also ban Red@Gold. Plain string items just use their key.
-- Ids travel opaquely through the ban wire format (item_key) and the selection UI.
local function item_id(item)
	if type(item) == "table" then
		if item.stake ~= nil then
			return item.key .. "@" .. tostring(item.stake)
		end
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

local function item_for_id(state, id)
	for _, item in ipairs(state.pool) do
		if item_id(item) == id then
			return item
		end
	end
	return nil
end

-- Survivors = pool minus banned, in pool order, as ITEMS (keys or {key,meta} tables).
local function compute_survivors(state)
	local out = {}
	for _, item in ipairs(state.pool) do
		if not state.banned[item_id(item)] then
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
		if not state.banned[item_id(item)] then
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
		if #out < cap and item_for_id(state, k) and not state.banned[k] then
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
		local id = item_id(item)
		if not state.banned[id] then
			eligible[#eligible + 1] = id
		end
	end
	local out = {}
	local needed = selection_needed(state)
	while #out < needed and #eligible > 0 do
		out[#out + 1] = table.remove(eligible, rng(#eligible))
	end
	return out
end

-- Test-only seam (dev/test_banpick_selection.lua). Attached only under
-- MPAPI._TEST so it is never present on shipped clients.
if MPAPI._TEST then
	BP._selection = {
		needed = selection_needed,
		contains = selection_contains,
		toggle = selection_toggle,
		prune = selection_prune,
		randomize = selection_randomize,
		list = function()
			return _selected
		end,
		-- test seams: is blind-random armed? / the live UI strings / inject fake
		-- tile areas so sync_selection_ui is coverable headless
		armed = function()
			return _random_armed
		end,
		ui = function()
			return _sel_ui
		end,
		set_areas = function(areas)
			_areas = areas
		end,
	}
end

-- Test-only seam for the draft-identity guard (dev/test_banpick_events.lua).
-- Attached only under MPAPI._TEST so it is never present on shipped clients.
if MPAPI._TEST then
	BP._draft_guard = {
		current_draft = function()
			return _current_draft_id
		end,
		is_dead = function(id)
			return _dead_drafts[id] == true
		end,
		reset = function()
			_current_draft_id = nil
			_dead_drafts = {}
			_draft_counter = 0
		end,
	}
end

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

-- Re-derive every tile's raised/tagged state and the live texts (counter +
-- button labels) from _selected. When blind-random is armed the counter reads
-- ?/N (the picks don't exist yet), Confirm reads "Confirm Random", and the
-- Random button flips to "Cancel Random".
local function sync_selection_ui(state)
	local step = current_step(state)
	local is_pick = step and step.action == "pick"
	if _random_armed then
		_sel_ui.count_text = '?/' .. tostring(selection_needed(state))
		_sel_ui.confirm_text = localize('k_banpick_confirm_random')
		_sel_ui.random_text = localize('k_banpick_cancel_random')
	else
		_sel_ui.count_text = tostring(#_selected) .. '/' .. tostring(selection_needed(state))
		_sel_ui.confirm_text = localize(is_pick and 'k_banpick_confirm_pick' or 'k_banpick_confirm')
		_sel_ui.random_text = localize('k_banpick_random')
	end
	local step = current_step(state)
	local action = step and step.action or "ban"
	for _, area in ipairs(_areas) do
		for _, card in ipairs(area.cards or {}) do
			if card.mp_item_id then
				set_card_selected(card, selection_contains(_selected, card.mp_item_id), action)
			end
		end
	end
end

-- Stake-column build is split in two (BP._stake_column): gather_stake_column runs
-- every fallible call (pool lookups, loc_vars, localize) into a caller-owned
-- collector; build_stake_column then assembles UI nodes from the completed gather.
-- The split matters because localize{type='descriptions'} CONSTRUCTS live
-- DynaText/UIBox objects the moment it runs (they self-register into G.I.MOVEABLE) --
-- each nodes table is parked in gathered.line_sets BEFORE that call, so a mid-gather
-- failure still leaves every object reachable for release_stake_column, never
-- orphaned at the screen origin.
local function release_line_nodes(node)
	if type(node) ~= "table" then
		return
	end
	local obj = node.config and node.config.object
	if obj and obj.remove then
		obj:remove()
	end
	for _, child in ipairs(node.nodes or node) do
		release_line_nodes(child)
	end
end

local function release_stake_column(gathered)
	for _, lines in ipairs(gathered.line_sets or {}) do
		for _, line in ipairs(lines) do
			release_line_nodes(line)
		end
	end
end

-- Mutates `gathered` ({ descs = {}, line_sets = {} }); sets gathered.ready
-- only when every fallible call completed. Caller owns the collector so a
-- thrown error still leaves the partial gather reachable for release.
local function gather_stake_column(item, gathered)
	local stakes_pool = G.P_CENTER_POOLS and G.P_CENTER_POOLS.Stake
	local top = stakes_pool and stakes_pool[item.stake]
	if not top then
		return
	end
	gathered.name = localize({ type = 'name_text', set = 'Stake', key = top.key })
	gathered.name_colour = get_stake_col(item.stake)
	if item.stake > 2 then
		gathered.also_applied = localize('k_also_applied')
	end
	local function gather_desc(i, drop_last)
		local center = stakes_pool[i]
		local res = {}
		if center.loc_vars and type(center.loc_vars) == 'function' then
			res = center:loc_vars() or {}
		end
		local lines = {}
		gathered.line_sets[#gathered.line_sets + 1] = lines
		localize({
			type = 'descriptions',
			key = res.key or center.key,
			set = res.set or center.set,
			nodes = lines,
			vars = res.vars or {},
		})
		-- Previous stakes drop their trailing "applies all previous Stakes"
		-- boilerplate line, exactly like run-info -- released here, while any
		-- objects localize built into it are still reachable.
		if drop_last and #lines > 1 then
			release_line_nodes(lines[#lines])
			lines[#lines] = nil
		end
		gathered.descs[#gathered.descs + 1] = { colour = get_stake_col(i), lines = lines }
	end
	gather_desc(item.stake, false)
	for i = item.stake - 1, 2, -1 do
		gather_desc(i, true)
	end
	gathered.ready = true
end

-- Pure assembly: table constructors over fully-gathered data only. descs[1] is
-- the tile's own stake; the rest are the cumulative previous stakes (desc, then
-- the "Also applied:" label after the first when present).
local function build_stake_column(gathered)
	local right = {}
	local function chip_desc_row(colour, rows)
		return {
			n = G.UIT.R,
			config = { align = "cm", padding = 0.03 },
			nodes = {
				{
					n = G.UIT.C,
					config = { align = "cm" },
					nodes = {
						{ n = G.UIT.C, config = { align = "cm", colour = colour, r = 0.1, minh = 0.3, minw = 0.3, emboss = 0.05 }, nodes = {} },
						{ n = G.UIT.B, config = { w = 0.08, h = 0.08 } },
					},
				},
				{ n = G.UIT.C, config = { align = "cm", padding = 0.03, colour = G.C.WHITE, r = 0.1, minh = 0.5, minw = 3.2 }, nodes = rows },
			},
		}
	end
	right[#right + 1] = {
		n = G.UIT.R,
		config = { align = "cm", r = 0.1, minw = 2.5, maxw = 4.2, minh = 0.4 },
		nodes = {
			{
				n = G.UIT.T,
				config = {
					text = gathered.name,
					scale = 0.38,
					colour = gathered.name_colour,
					shadow = true,
				},
			},
		},
	}
	for idx, d in ipairs(gathered.descs) do
		local rows = {}
		for _, line in ipairs(d.lines) do
			rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm" }, nodes = line }
		end
		right[#right + 1] = chip_desc_row(d.colour, rows)
		if idx == 1 and gathered.also_applied then
			right[#right + 1] = {
				n = G.UIT.R,
				config = { align = "cm", padding = 0.03 },
				nodes = {
					{ n = G.UIT.T, config = { text = gathered.also_applied, scale = 0.32, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				},
			}
		end
	end
	return right
end

-- Test-only seam (dev/test_banpick_selection.lua). Attached only under
-- MPAPI._TEST so it is never present on shipped clients.
if MPAPI._TEST then
	BP._stake_column = {
		gather = gather_stake_column,
		build = build_stake_column,
		release = release_stake_column,
	}
end

-- Pure vertical-clamp decision for the hover popup (see card:hover). The engine's
-- Moveable alignment flips a popup above/below its tile but only ever clamps
-- horizontally (lr_clamp), so a popup taller than its side's space runs off screen
-- (e.g. the composition popup from the bottom row). Returns the y keeping the popup
-- inside [edge, room_h - edge]; bottom is applied first so the top-edge rule wins for
-- popups taller than the room -- the content's top is what must stay readable.
local function popup_clamp_y(y, h, room_h, edge)
	if y + h > room_h - edge then
		y = room_h - edge - h
	end
	if y < edge then
		y = edge
	end
	return y
end

-- Test-only seam (dev/test_banpick_popup_clamp.lua). Attached only under
-- MPAPI._TEST so it is never present on shipped clients.
if MPAPI._TEST then
	BP._popup = {
		clamp_y = popup_clamp_y,
	}
end

-- Keep a hover popup on screen. Two mechanisms, since the engine treats still and
-- moving anchors differently (Moveable:move gates move_with_major on `not STATIONARY
-- or NEW_ALIGNMENT`):
-- 1. STATIC anchors (badge, unmoving tile): a one-shot offset mutation before the
--    popup's first move raises NEW_ALIGNMENT, so the content tree re-aligns to the
--    clamped position. Clamping T/VT directly would NOT work: a stationary popup's
--    content tree never re-follows its outer box.
-- 2. MOVING anchors (a raised tile carrying the popup): a per-frame clamp of the
--    outer transforms, since the content tree re-follows every frame anyway.
-- lr_clamp covers the horizontal axis for wide popups.
local function clamp_popup(popup, anchor)
	if not popup or not popup.T or popup._mp_tb_clamp then
		return
	end
	popup._mp_tb_clamp = true
	-- NOTE: vanilla Card:move re-calls set_alignment(align_h_popup()) EVERY frame,
	-- resetting alignment.lr_clamp and offset -- so for TILE anchors the one-shot
	-- mutation above is overwritten before it acts, and the per-frame wrapper below
	-- is the only mechanism that holds (it clamps both axes). UIElement anchors like
	-- the badge have no such realignment, so the one-shot offset works for them.
	local a = popup.alignment
	if a then
		a.lr_clamp = true
		if a.offset and anchor and anchor.T then
			-- Recreate the engine's alignment geometry for the popup top
			-- (align_to_major: 't' -> above the anchor, 'b' -> below it).
			local t = tostring(a.type or '')
			local top
			if t:find('t') then
				top = anchor.T.y + a.offset.y - popup.T.h
			elseif t:find('b') then
				top = anchor.T.y + anchor.T.h + a.offset.y
			end
			if top then
				a.offset.y = a.offset.y + (popup_clamp_y(top, popup.T.h, G.ROOM.T.h, 0.05) - top)
			end
		end
	end
	local base_move = popup.move
	popup.move = function(p, dt)
		base_move(p, dt)
		p.T.y = popup_clamp_y(p.T.y, p.T.h, G.ROOM.T.h, 0.05)
		p.VT.y = popup_clamp_y(p.VT.y, p.VT.h, G.ROOM.T.h, 0.05)
		-- Same clamp horizontally (bounds [0, room_w], mirroring lr_clamp).
		p.T.x = popup_clamp_y(p.T.x, p.T.w, G.ROOM.T.w, 0)
		p.VT.x = popup_clamp_y(p.VT.x, p.VT.w, G.ROOM.T.w, 0)
	end
end

-- LAZY popup-row builders: DynaText/UIBox objects register themselves
-- globally the moment they are constructed, so anything built and then NOT
-- placed in a drawn popup would still be drawn -- unparented, at the screen
-- origin (the garbled text-over-the-status-panel bug). Only ever call these
-- from inside a hover that immediately places the result.
local function popup_name_row(text, name_scale)
	return {
		n = G.UIT.R,
		config = { align = "cm", r = 0.1, minw = 3, maxw = 4, minh = 0.4 },
		nodes = {
			{
				n = G.UIT.O,
				config = {
					object = DynaText({
						string = text,
						maxw = 4,
						colours = { G.C.WHITE }, shadow = true, bump = true, scale = name_scale, pop_in = 0, silent = true,
					}),
				},
			},
		},
	}
end
local function popup_desc_row(center)
	return {
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
						definition = Back(center):generate_UI(),
						config = { offset = { x = 0, y = 0 } },
					}),
				},
			},
		},
	}
end

-- Title rows for a composite item's popup: its `name` (a display title the
-- consumer sets verbatim -- the engine is composite-agnostic and never adds
-- words like "Cocktail" itself) and optional `subtitle`. Both shared by the
-- tile hover and the badge detail.
local function composition_header(item)
	local rows = {}
	if item.name then
		rows[#rows + 1] = popup_name_row(tostring(item.name), 0.5)
	end
	if item.subtitle then
		rows[#rows + 1] = {
			n = G.UIT.R,
			config = { align = "cm", r = 0.1, minw = 3, maxw = 4, minh = 0.35 },
			nodes = {
				{ n = G.UIT.T, config = { text = tostring(item.subtitle), scale = 0.32, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			},
		}
	end
	return rows
end

-- Compact composition rows for the TILE hover: header + contained deck
-- names only, no effect boxes -- the full breakdown lives in the badge's
-- detail popup.
local function composition_rows(item)
	local rows = composition_header(item)
	for _, ckey in ipairs(item.decks) do
		local ccenter = G.P_CENTERS[ckey]
		if ccenter then
			rows[#rows + 1] = popup_name_row(Back(ccenter):get_name(), 0.38)
		end
	end
	return rows
end

-- The badge's full detail: header, then the contained decks laid out
-- SIDE BY SIDE -- one column per deck, name over effects. Horizontal on
-- purpose: three stacked descriptions are taller than any screen position
-- can guarantee, while three columns stay ~2 units tall and always fit.
local function composition_detail(item)
	local cols = {}
	for _, ckey in ipairs(item.decks) do
		local ccenter = G.P_CENTERS[ckey]
		if ccenter then
			cols[#cols + 1] = {
				n = G.UIT.C,
				config = { align = "tm", padding = 0.05 },
				nodes = {
					popup_name_row(Back(ccenter):get_name(), 0.38),
					popup_desc_row(ccenter),
				},
			}
		end
	end
	local rows = composition_header(item)
	rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm" }, nodes = cols }
	return rows
end

-- Shared visual wrapper for both hover popups (tile + badge): the outlined
-- dark container the columns sit in.
local function popup_container(columns)
	return {
		n = G.UIT.C,
		config = { align = "cm", padding = 0.1 },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = "cm", r = 0.1, colour = G.C.L_BLACK, padding = 0.1, outline = 1 },
				nodes = {
					{ n = G.UIT.R, config = { align = "tm" }, nodes = columns },
				},
			},
		},
	}
end

-- Tile hover popup: mod badges (top of the panel) built via the vanilla
-- SMODS helper; mod_set is stripped the same as before (never shown here).
local function build_hover_mod_badges(center)
	local badges = { n = G.UIT.C, config = { colour = G.C.CLEAR, align = "cm" }, nodes = {} }
	SMODS.create_mod_badges(center, badges.nodes)
	if badges.nodes.mod_set then
		badges.nodes.mod_set = nil
	end
	return badges
end

-- Left column of the tile hover: deck info (name+desc, or compact composition rows
-- for a composite item), then mod badges. COMPACT for composite items on purpose --
-- full per-deck details live in the composition badge's popup instead, since a tile
-- tooltip tall enough for three descriptions would cover the row it points at.
local function build_hover_left_column(item, center, badges)
	local left = {}
	local has_composition = type(item) == "table" and type(item.decks) == "table"
	if has_composition then
		for _, row in ipairs(composition_rows(item)) do
			left[#left + 1] = row
		end
	else
		left[#left + 1] = popup_name_row(Back(center):get_name(), 0.5)
		left[#left + 1] = popup_desc_row(center)
	end
	if badges.nodes[1] then
		left[#left + 1] = {
			n = G.UIT.R,
			config = { align = "cm", r = 0.1, minw = 3, maxw = 4, minh = 0.4 },
			nodes = { badges },
		}
	end
	return left
end

-- Right column of the tile hover: the stake column (gather_stake_column /
-- build_stake_column above), only for tuple-pool items with a numeric stake.
-- Two-phase gather -> build inside a pcall: a loc failure degrades to a logged
-- warning with every already-constructed object released -- never a dead hover.
local function build_hover_right_column(item)
	local right = {}
	if type(item) == "table" and type(item.stake) == "number" then
		local gathered = { descs = {}, line_sets = {} }
		local ok, err = pcall(gather_stake_column, item, gathered)
		if ok and gathered.ready then
			right = build_stake_column(gathered)
		elseif not ok then
			release_stake_column(gathered)
			MPAPI.sendWarnMessage('[banpick] stake column failed: ' .. tostring(err))
		end
	end
	return right
end

-- One deck tile: a card showing the deck's Back center. `item` may carry metadata; the
-- consumer's decorate_tile(card, item) is called after emplace (e.g. to stamp a stake
-- sticker via card.sticker). BANNED tiles are debuffed.
local function deck_tile(item, banned, area, decorate)
	local key = item_key(item)
	local id = item_id(item)
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
	-- Identity is the item ID (key+stake for tuples): marking Red@White must not
	-- raise or ban the Red@Gold tile sitting next to it.
	card.mp_item_id = id

	-- Clicking toggles the mark; nothing commits here (that's the Confirm button).
	-- Off-turn and banned tiles don't react at all.
	function card:click()
		local lobby = MPAPI.get_current_lobby()
		local state = lobby and lobby._ban_pick
		if banned or not state or not is_my_turn(lobby, state) then
			return
		end
		-- Touching a tile leaves blind-random mode: manual selection resumes.
		_random_armed = false
		selection_toggle(_selected, id, selection_needed(state))
		sync_selection_ui(state)
	end

	-- Selection drives the raise through set_card_selected; neuter the vanilla
	-- highlight (it would spawn run-context joker buttons on these tiles).
	function card:highlight(is_higlighted)
		self.highlighted = is_higlighted
	end

	function card:hover()
		-- Two columns: deck info (left) and, for tuple pools, stake info (right).
		local badges = build_hover_mod_badges(self.config.center)
		local left = build_hover_left_column(item, self.config.center, badges)
		local right = build_hover_right_column(item)

		local columns = { { n = G.UIT.C, config = { align = "tm", padding = 0.05 }, nodes = left } }
		if right[1] then
			columns[#columns + 1] = { n = G.UIT.C, config = { align = "tm", padding = 0.05 }, nodes = right }
		end

		self.config.h_popup = { n = G.UIT.C, config = { align = "cm", padding = 0.1 }, nodes = {} }

		-- The 2-or-1 position comes from the vanilla card_h_popup pattern where
		-- nodes is pre-populated; here it is freshly EMPTY, so clamp the index or
		-- inserting at 2 leaves nodes[1] = nil -- an array hole every ipairs
		-- consumer stops at.
		local popup_nodes = self.config.h_popup.nodes
		table.insert(popup_nodes, math.min((self.T.x > G.ROOM.T.w * 0.4) and 2 or 1, #popup_nodes + 1), popup_container(columns))

		self.config.h_popup_config = self:align_h_popup()
		Node.hover(self)
		clamp_popup(self.children.h_popup, self)
	end
end

-- Per-frame init for the composition badge (config.func): installs a hover showing
-- the FULL composition (each deck's name + effects) as a popup growing DOWNWARD
-- from the badge (top-anchored on_demand_tooltip geometry). Sitting at the panel top
-- gives it the whole panel height to grow into, covering tiles only while read.
G.FUNCS.mpapi_composition_badge_init = function(e)
	if e._mp_badge_init then
		return
	end
	e._mp_badge_init = true
	e.states.collide.can = true
	e.states.hover.can = true
	e.hover = function(self)
		local it = self.config.mp_comp_item
		if not it then
			return
		end
		self.config.h_popup = popup_container({
			{ n = G.UIT.C, config = { align = "tm", padding = 0.05 }, nodes = composition_detail(it) },
		})
		self.config.h_popup_config = { align = 'bm', offset = { x = 0, y = 0.1 }, parent = self }
		Node.hover(self)
		clamp_popup(self.children.h_popup, self)
	end
	e.stop_hover = function(self)
		Node.stop_hover(self)
		self.config.h_popup = nil
	end
end

-- The always-visible composition badge row: "<Name>: Deck A + Deck B +
-- Deck C" at a glance, full details on hover (see the init func above).
-- Only built when the pool contains an item carrying a `decks` list. The
-- title is the item's `name` verbatim (the consumer owns the wording); an
-- item with no name falls back to just the deck list.
local function composition_badge_row(comp_item)
	local names = {}
	for _, ckey in ipairs(comp_item.decks) do
		local ccenter = G.P_CENTERS[ckey]
		if ccenter then
			names[#names + 1] = Back(ccenter):get_name()
		end
	end
	local decks_label = table.concat(names, ' + ')
	local label = comp_item.name and (tostring(comp_item.name) .. ': ' .. decks_label) or decks_label
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.04 },
		nodes = {
			{
				n = G.UIT.C,
				config = {
					align = 'cm', padding = 0.08, r = 0.1,
					colour = G.C.L_BLACK, outline = 1, outline_colour = G.C.UI.OUTLINE_LIGHT_TRANS,
					func = 'mpapi_composition_badge_init',
					mp_comp_item = comp_item,
				},
				nodes = {
					{ n = G.UIT.T, config = { text = label, scale = 0.32, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				},
			},
		},
	}
end

-- Title.
local function build_title_row()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_title'), scale = 0.6, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }
end

-- Status: whose turn (ban vs pick) + how many actions/decks remain.
local function build_status_rows(my_turn, is_pick, state, left)
	local status_text
	if not my_turn then
		status_text = localize('k_banpick_their_turn')
	elseif is_pick then
		status_text = localize('k_banpick_pick_turn')
	else
		status_text = localize('k_banpick_your_turn')
	end
	local status_colour = my_turn and G.C.GREEN or G.C.UI.TEXT_INACTIVE
	local status_row = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = status_text, scale = 0.42, colour = status_colour, shadow = true } },
	} }
	local detail = is_pick
		and (localize('k_banpick_decks_left') .. ' ' .. tostring(left))
		or (localize('k_banpick_bans_left') .. ' ' .. tostring(state.sched_remaining or 0) .. '   ' .. localize('k_banpick_decks_left') .. ' ' .. tostring(left))
	local detail_row = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = detail, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
	} }
	return status_row, detail_row
end

-- Composition badge (top of the panel, above the tiles): at-a-glance
-- composition, full per-deck details on hover. Only the FIRST composite item
-- gets a badge (matches the original `break` after the first match). Returns
-- nil when the pool has no composite item.
local function build_composition_badge_section(state)
	for _, item in ipairs(state.pool) do
		if type(item) == "table" and type(item.decks) == "table" then
			return composition_badge_row(item)
		end
	end
	return nil
end

-- The deck-tile grid: one CardArea per row of PER_ROW tiles, built left to
-- right through the pool. Returns the areas (for _areas / selection sync) and
-- the two rows (spacer + the grid itself) to append to the panel.
local function build_tile_grid(state, decorate)
	local areas = {}
	local areas_container = {}
	local cur_area = nil
	for i, item in ipairs(state.pool) do
		if (i - 1) % PER_ROW == 0 then
			-- Width beyond the cards' own footprint becomes even spacing between
			-- tiles (CardArea spreads its cards across the full width).
			cur_area = CardArea(0, 0, G.CARD_W * ROW_SCALE * PER_ROW * 1.15, G.CARD_H * ROW_SCALE, {
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
		deck_tile(item, state.banned[item_id(item)], cur_area, decorate)
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
	local grid_rows = {
		{ n = G.UIT.R, config = { minh = 0.25 } },
		{
			n = G.UIT.R,
			config = { align = "cm", padding = 0.25, r = 0.25, colour = { 0, 0, 0, 0.1 } },
			nodes = areas_container,
		},
	}
	return areas, grid_rows
end

-- Selected counter row: "Selected: N/M", live via ref_table.
local function build_selected_counter_row()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_selected') .. ' ', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
		{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'count_text', scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
	} }
end

-- Confirm + Random buttons. ALWAYS rendered -- on the opponent's turn the check
-- funcs grey both out (inactive colour, config.button nulled) instead of the row
-- vanishing, keeping one stable layout. `button` must be present at definition time
-- (UIElement:set_values only arms click for nodes that HAVE it at UIBox build); the
-- per-frame check then nulls it while not ready (vanilla can_play pattern). Random
-- is deliberately NOT one_press: pressing it again re-rolls.
local function build_action_buttons_row()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
		{
			n = G.UIT.C,
			config = {
				align = 'cm', minw = 3.2, minh = 0.7, r = 0.1, padding = 0.08,
				shadow = true, hover = true, colour = G.C.UI.BACKGROUND_INACTIVE,
				button = 'mpapi_ban_pick_confirm', one_press = true,
				func = 'mpapi_ban_pick_confirm_check',
			},
			nodes = {
				{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'confirm_text', scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			},
		},
		{ n = G.UIT.C, config = { minw = 0.25 } },
		{
			n = G.UIT.C,
			config = {
				-- Wide enough for its longest live label ("Cancel Random").
				align = 'cm', minw = 2.6, minh = 0.7, r = 0.1, padding = 0.08,
				shadow = true, hover = true, colour = G.C.UI.BACKGROUND_INACTIVE,
				button = 'mpapi_ban_pick_random',
				func = 'mpapi_ban_pick_random_check',
			},
			nodes = {
				{ n = G.UIT.T, config = { ref_table = _sel_ui, ref_value = 'random_text', scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			},
		},
	} }
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

	rows[#rows + 1] = build_title_row()

	local status_row, detail_row = build_status_rows(my_turn, is_pick, state, left)
	rows[#rows + 1] = status_row
	rows[#rows + 1] = detail_row

	local badge_row = build_composition_badge_section(state)
	if badge_row then
		rows[#rows + 1] = badge_row
	end

	local decorate = _config and _config.decorate_tile
	local areas, grid_rows = build_tile_grid(state, decorate)
	for _, r in ipairs(grid_rows) do
		rows[#rows + 1] = r
	end

	-- Re-apply any surviving selection to the freshly built tiles (the overlay is
	-- rebuilt on every state broadcast; _selected was pruned in on_state).
	_areas = areas
	sync_selection_ui(state)

	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.4 } }
	rows[#rows + 1] = build_selected_counter_row()
	rows[#rows + 1] = build_action_buttons_row()

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
	local s = lobby._ban_pick
	lobby:action(action_type):broadcast({ state = s })
end

-- Host authority: apply `from_player_id`'s action (ban or pick, per the current schedule
-- step) on the given item id. Returns true if it was legal and changed state (caller broadcasts).
-- Exported as apply_ban for backward compatibility with existing consumer ActionTypes.
-- `id` is the pool item's identity (item_id): the plain key for string pools,
-- key@stake for tuple pools. It arrives opaquely through the consumers' ban
-- ActionType (their item_key parameter), so consumers need no changes.
local function apply_action(lobby, from_player_id, id)
	local s = lobby._ban_pick
	if not s or s.complete then
		return false
	end
	if current_actor_id(s) ~= from_player_id then
		return false
	end
	if not item_for_id(s, id) or s.banned[id] then
		return false
	end

	local step = current_step(s)
	if step and step.action == "pick" then
		-- The picked item wins; everything else is discarded.
		s.survivors = { item_for_id(s, id) }
		s.complete = true
		return true
	end

	-- Ban. `ban_order` records the sequence bans happened in -- unused by legacy
	-- survivors-only consumers, but lets a `keep=0` draft use the order itself as the
	-- result (e.g. SPDRN's All Deck mode drafting play order, see all_deck.lua).
	-- ban_order stores the ITEM (same shape as survivors) so on_complete's two args
	-- stay consistently keys-or-{key,meta}-tables regardless of pool kind.
	s.banned[id] = true
	s.ban_order[#s.ban_order + 1] = item_for_id(s, id) or id
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

-- Called by the Confirm flow (any client) with a pool item ID. Host applies
-- directly; guest asks the host (the wire parameter stays named item_key for
-- consumer ActionType compatibility -- it carries the item id opaquely).
function BP.request_ban(id)
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		return
	end
	local s = lobby._ban_pick
	if not is_my_turn(lobby, s) then
		return
	end

	if lobby.is_host then
		if apply_action(lobby, lobby.player_id, id) then
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
			lobby:action(action_type):send(s.order[1], { item_key = id })
		end
	end
end

function BP.on_state(lobby, state)
	if not state then
		return
	end
	-- Draft-identity guard, scoped by draft_id (see the module-local comment).
	if state.draft_id then
		if _dead_drafts[state.draft_id] then
			return
		end
		if state.draft_id ~= _current_draft_id then
			-- First sight of a new draft (possibly from a different host):
			-- supersede the old draft so a late duplicate of it can't reappear.
			if _current_draft_id then
				_dead_drafts[_current_draft_id] = true
			end
			_current_draft_id = state.draft_id
		end
	end
	lobby._ban_pick = state

	-- Drop marks the broadcast invalidated (opponent banned them, cap shrank),
	-- and disarm blind-random -- arming is cheap to redo and never stale.
	_selected = selection_prune(_selected, state)
	_random_armed = false

	if _overlay then
		_overlay:update()
	elseif _render then
		_render()
	end

	if state.complete and not _fired then
		_fired = true
		-- The draft is over: any further broadcast bearing this id is a duplicate.
		if state.draft_id then
			_dead_drafts[state.draft_id] = true
		end
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
			cb(state.survivors or {}, state.ban_order or {})
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
-- }. on_complete(survivors, ban_order) receives the surviving items (keys or {key,meta}
-- tables) plus the full ban sequence (also keys/tables) -- useful for a `keep=0` draft, where
-- `survivors` is always empty and the ban order itself is the meaningful result.
function BP.start(lobby, config, on_complete)
	_config = config
	_on_complete = on_complete
	_fired = false
	_selected = {}
	_areas = {}
	_random_armed = false

	-- A new draft invalidates the previous one. Clearing state matters on GUESTS
	-- (host reassigns below anyway): otherwise the old COMPLETE state renders as a
	-- live board while the host's async pool fetch is still running. Dead-marking
	-- the old draft_id stops a late duplicate from completing the NEW draft with
	-- stale survivors.
	lobby._ban_pick = nil
	if _current_draft_id then
		_dead_drafts[_current_draft_id] = true
	end
	_current_draft_id = nil

	if lobby.is_host then
		local pool = (config.build_pool and config.build_pool()) or default_build_pool(config.pool_size)
		local schedule = config.schedule or derive_schedule(config.pool_size or #pool, config.keep or 1)
		-- Unique per draft: host id + wall clock + session counter. Guests scope
		-- the draft-identity guard to this id, so it is never compared across
		-- drafts or across hosts.
		_draft_counter = _draft_counter + 1
		local draft_id = tostring(lobby.player_id) .. '#' .. tostring(os.time()) .. '#' .. tostring(_draft_counter)
		_current_draft_id = draft_id
		lobby._ban_pick = {
			draft_id = draft_id,
			pool = pool,
			banned = {},
			ban_order = {},
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
	local ready = s and is_my_turn(lobby, s) and needed > 0 and (#_selected == needed or _random_armed)
	if ready then
		-- Green = "go", always: Confirm Ban / Confirm Pick / Confirm Random all
		-- share the confirm signal colour (the label carries the meaning).
		e.config.colour = G.C.GREEN
		e.config.button = "mpapi_ban_pick_confirm"
	else
		e.config.colour = G.C.UI.BACKGROUND_INACTIVE
		e.config.button = nil
	end
end

-- Random: BLIND commit. Pressing Random arms random mode -- it clears any
-- manual marks, raises nothing, reveals nothing (counter reads ?/N, the button
-- goes green). Confirm then rolls the actual picks at commit time and sends
-- them through; there is nothing to peek at or reroll-fish for. Pressing
-- Random again (or clicking any tile) disarms back to manual selection.
G.FUNCS.mpapi_ban_pick_random_check = function(e)
	local lobby = MPAPI.get_current_lobby()
	local s = lobby and lobby._ban_pick
	if s and is_my_turn(lobby, s) and selection_needed(s) > 0 then
		-- Idle: blue "Random". Armed: red "Cancel Random" (red = back out; the
		-- green go-signal lives on Confirm).
		e.config.colour = _random_armed and G.C.RED or G.C.BLUE
		e.config.button = "mpapi_ban_pick_random"
	else
		e.config.colour = G.C.UI.BACKGROUND_INACTIVE
		e.config.button = nil
	end
end

G.FUNCS.mpapi_ban_pick_random = function(_e)
	local lobby = MPAPI.get_current_lobby()
	local s = lobby and lobby._ban_pick
	if not s or not is_my_turn(lobby, s) then
		return
	end
	_random_armed = not _random_armed
	if _random_armed then
		_selected = {}
	end
	sync_selection_ui(s)
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
	if needed == 0 then
		return
	end
	local ids
	if _random_armed then
		-- Blind random: the picks are rolled HERE, at commit time -- the player
		-- confirmed "random", never a revealed selection.
		_random_armed = false
		ids = selection_randomize(s)
		-- A short roll (eligible survivors < the step's remaining count) commits
		-- NOTHING: a partial batch would exhaust the pool mid-step and wedge the
		-- draft with no legal action left. Disarm, warn, leave the step intact.
		if #ids < needed then
			MPAPI.sendWarnMessage('[banpick] blind random rolled ' .. tostring(#ids) .. ' of ' .. tostring(needed) .. ' needed; nothing committed')
			sync_selection_ui(s)
			return
		end
	else
		if #_selected ~= needed then
			return
		end
		ids = _selected
	end
	_selected = {}
	for _, id in ipairs(ids) do
		BP.request_ban(id)
	end
	-- On the host every applied action re-renders (masking this); on a GUEST
	-- request_ban only sends the wire message, so without an explicit sync the
	-- tiles keep their raised state + Selected tags and the counter reads a full
	-- N/N until the host's rebroadcast lands.
	sync_selection_ui(s)
end
