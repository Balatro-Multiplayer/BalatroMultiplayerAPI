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

local PER_ROW = 5

-- One deck tile: a coloured name box, plus (when it's your turn) a Ban button, or a
-- BANNED marker once removed. Mirrors the leaderboard's value_box / entry_row styling.
local function deck_tile(key, banned, my_turn)
	local center = G.P_CENTERS[key]
	local name = (center and center.name) or key
	local box_colour = banned and G.C.UI.BACKGROUND_INACTIVE or darken(G.C.JOKER_GREY, 0.1)

	local nodes = {
		{ n = G.UIT.R, config = { align = 'cm', minw = 1.9, minh = 0.55, padding = 0.05, r = 0.07, colour = box_colour, emboss = 0.04 }, nodes = {
			{ n = G.UIT.T, config = { text = name, scale = 0.34, colour = banned and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT, shadow = true } },
		} },
	}

	if banned then
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_banpick_banned'), scale = 0.3, colour = G.C.RED, shadow = true } },
		} }
	elseif my_turn then
		-- Built as a raw button node (config.ref_table + button) rather than via
		-- UIBox_button so the deck key reliably reaches the handler -- the proven
		-- pattern for passing per-card context to a button click in this codebase.
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
			{ n = G.UIT.C, config = { ref_table = { deck_key = key }, align = 'cm', minw = 1.9, minh = 0.42, padding = 0.06, r = 0.08, colour = G.C.RED, hover = true, shadow = true, one_press = true, button = 'mpapi_ban_pick_ban' }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_banpick_ban'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
		} }
	else
		-- Reserve the button's height so tiles stay the same size on either turn.
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', minh = 0.5 }, nodes = {} }
	end

	return { n = G.UIT.C, config = { align = 'cm', padding = 0.06 }, nodes = nodes }
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
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_banpick_bans_left') .. ' ' .. tostring(state.bans_remaining) .. '   ' .. localize('k_banpick_decks_left') .. ' ' .. tostring(survivors_left) .. ' / ' .. tostring(state.keep), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
	} }

	-- Deck grid, PER_ROW tiles per row.
	local cur_row = nil
	for i, key in ipairs(state.pool) do
		if (i - 1) % PER_ROW == 0 then
			cur_row = { n = G.UIT.R, config = { align = 'cm' }, nodes = {} }
			rows[#rows + 1] = cur_row
		end
		cur_row.nodes[#cur_row.nodes + 1] = deck_tile(key, state.banned[key], my_turn)
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
	end

	if state.complete and not _fired then
		_fired = true
		local cb = _on_complete
		_on_complete = nil
		_overlay = nil
		if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
			G.FUNCS.exit_overlay_menu()
		end
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

	_overlay = MPAPI.ui_element(build_banpick_uibox)
	_overlay:as_overlay()

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
