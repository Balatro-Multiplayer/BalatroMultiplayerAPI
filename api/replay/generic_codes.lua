-- Shared generic-action MPAPI.RLOG_CODEs (api/replay/codes.lua) -- the base
-- opcode vocabulary every consuming mod's core Balatro loop needs (play,
-- discard, buy, sell, use, pack_pick, pack_skip, reroll, reorder, cashout,
-- select_blind, skip_blind, money_delta), ported from
-- BalatroMultiplayerPvP's overrides/game.lua + ui/game/functions.lua +
-- ui/game/timer.lua and BalatroMultiplayerSpeed's objects/replay_log/record.lua
-- (independently-written but near-identical ports of the same original code).
--
-- Each vanilla G.FUNCS/global function is now wrapped exactly ONCE, here,
-- instead of once per installed mod -- this is the fix for the double-record
-- bug (both mods' hooks firing for the same action when both are installed,
-- previously worked around with a per-call MPAPI.is_active(mod_id) ownership
-- guard). Gating is `RLOG.is_active()` alone now: that guard existed only to
-- disambiguate which of two INDEPENDENTLY installed hooks should fire: with
-- exactly one hook installed, that question no longer exists, and
-- RLOG.record() itself already no-ops with no active lobby regardless.
--
-- `replay` on each code below is a mod-agnostic BASELINE (real action for the
-- POV player, safe no-op otherwise) -- it exists because RLOG_CODE requires a
-- replay function, and it's what a future third consuming mod gets for free.
-- In practice, for 'pvp' and 'spdrn' specifically, it never runs: both mods'
-- own playback_handlers.lua files (loaded after MPAPI, since MPAPI is a
-- dependency both mods load after) independently call
-- MPAPI.playback.register_handler(mod_id, opcode, fn) for every one of these
-- opcodes with their own fuller implementations (PvP's adds non-POV opponent-
-- HUD projection and extra pre/post-condition handling for select_blind/
-- skip_blind/sell that only make sense in a PvP context) -- a later
-- register_handler call for the same (mod_id, opcode) simply overwrites this
-- one, by design (see api/playback/registry.lua). This file intentionally
-- never reaches into a specific consuming mod's own globals (e.g. PVP.GAME) --
-- that's exactly the coupling this generic layer exists to avoid.
local RLOG = MPAPI.replay
local AREA = RLOG.AREA

local function highlight_hand_indices(indices)
	for _, i in ipairs(indices or {}) do
		local card = G.hand.cards[i]
		if card then G.hand:add_to_highlighted(card) end
	end
end

-------------------------------------------------------------------------------
-- RLOG_CODE definitions
-------------------------------------------------------------------------------

MPAPI.RLOG_CODE {
	key = 'money_delta',
	mods = { 'pvp', 'spdrn' },
	-- Bare-scalar args (the delta amount itself, not a table) -- matches
	-- fmt_args' bare-scalar handling in recorder.lua.
	write = function(self, delta)
		self:record(delta)
	end,
	-- Pure bookkeeping: the real dollar change already happens as a side
	-- effect of whatever action caused it (buy/sell/etc, each its own code),
	-- nothing to apply.
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			-- no-op
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'sell',
	mods = { 'pvp', 'spdrn' },
	write = function(self, area, idx, ref, human)
		self:record({ area, idx, ref }, human)
	end,
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local area_id, idx = args and args[1], args and args[2]
			local area = RLOG.area_object(area_id)
			local card = area and area.cards and area.cards[idx]
			if card then
				card:sell_card()
				SMODS.calculate_context({ selling_card = true, card = card })
			end
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'cashout',
	mods = { 'pvp', 'spdrn' },
	write = function(self)
		self:record(nil, "action:cashOut")
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			if ctx.is_pov then G.FUNCS.cash_out({ config = {} }) end
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'reroll',
	mods = { 'pvp', 'spdrn' },
	write = function(self, human)
		self:record(nil, human)
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			if ctx.is_pov then G.FUNCS.reroll_shop({ config = {} }) end
		end
	end,
}

-- buy/open_pack/voucher share one write shape and one hook site (the opcode
-- chosen dynamically by the bought card's set, see the buy_from_shop hook
-- below) but are three distinct RLOG_CODEs, one per opcode string.
local function shop_purchase_write(self, area, idx, ref, cost, human)
	-- cost trails the existing {area, idx, ref} positions -- appended, not
	-- inserted, so any reader keying off args[1]/args[2] (area/idx) is
	-- unaffected by its presence.
	self:record({ area, idx, ref, cost }, human)
end
local function shop_purchase_replay(self, args, ctx)
	if ctx.schema_version >= 1 then
		if not ctx.is_pov then return end
		local area_id, idx = args and args[1], args and args[2]
		local area = RLOG.area_object(area_id)
		local card = area and area.cards and area.cards[idx]
		if card then G.FUNCS.buy_from_shop({ config = { ref_table = card } }) end
	end
end

MPAPI.RLOG_CODE { key = 'buy', mods = { 'pvp', 'spdrn' }, write = shop_purchase_write, replay = shop_purchase_replay }
MPAPI.RLOG_CODE {
	key = 'open_pack',
	mods = { 'pvp', 'spdrn' },
	write = shop_purchase_write,
	replay = shop_purchase_replay,
}
MPAPI.RLOG_CODE {
	key = 'voucher',
	mods = { 'pvp', 'spdrn' },
	write = shop_purchase_write,
	replay = shop_purchase_replay,
}

-- use/pack_pick share one write shape and one hook site (G.FUNCS.use_card;
-- the opcode is chosen by whether the card being used lives in G.pack_cards).
local function use_write(self, idx, targets, ref, target_refs, human)
	self:record({ idx, targets, ref, target_refs }, human)
end
MPAPI.RLOG_CODE {
	key = 'use',
	mods = { 'pvp', 'spdrn' },
	write = use_write,
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local idx, targets = args and args[1], args and args[2]
			local card = G.consumeables and G.consumeables.cards and G.consumeables.cards[idx]
			if not card then return end
			if targets then highlight_hand_indices(targets) end
			G.FUNCS.use_card({ config = { ref_table = card } })
		end
	end,
}
MPAPI.RLOG_CODE {
	key = 'pack_pick',
	mods = { 'pvp', 'spdrn' },
	write = use_write,
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local idx, targets = args and args[1], args and args[2]
			local card = G.pack_cards and G.pack_cards.cards and G.pack_cards.cards[idx]
			if not card then return end
			if targets then highlight_hand_indices(targets) end
			G.FUNCS.use_card({ config = { ref_table = card } })
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'pack_skip',
	mods = { 'pvp', 'spdrn' },
	write = function(self, refs)
		self:record({ refs }, "action:skipPack")
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			if ctx.is_pov then G.FUNCS.skip_booster({ config = {} }) end
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'reorder',
	mods = { 'pvp', 'spdrn' },
	write = function(self, area_id, perm, moved, human)
		self:record({ area_id, perm, moved }, human)
	end,
	-- perm is "new-position -> old-index": new_cards[j] = old_cards[perm[j]].
	-- Direct-splice, mirrors vanilla's own sort-button pattern.
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local area_id, perm = args and args[1], args and args[2]
			local area = RLOG.area_object(area_id)
			if not (area and perm) then return end
			local old_cards = area.cards
			local new_cards = {}
			for j = 1, #perm do
				new_cards[j] = old_cards[perm[j]]
			end
			area.cards = new_cards
			if area.set_ranks then area:set_ranks() end
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'play',
	mods = { 'pvp', 'spdrn' },
	write = function(self, played, played_refs, human)
		self:record({ played, played_refs }, human)
	end,
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local indices = args and args[1]
			if not indices then return end
			highlight_hand_indices(indices)
			G.FUNCS.play_cards_from_highlighted()
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'discard',
	mods = { 'pvp', 'spdrn' },
	write = function(self, discarded, discarded_refs, human)
		self:record({ discarded, discarded_refs }, human)
	end,
	replay = function(self, args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local indices = args and args[1]
			if not indices then return end
			highlight_hand_indices(indices)
			G.FUNCS.discard_cards_from_highlighted(nil, false)
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'select_blind',
	mods = { 'pvp', 'spdrn' },
	write = function(self, human)
		self:record(0, human)
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			if not ctx.is_pov then return end
			local blind_key = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
			G.FUNCS.select_blind({ config = { ref_table = G.P_BLINDS[blind_key] }, UIBox = G.blind_select })
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'skip_blind',
	mods = { 'pvp', 'spdrn' },
	write = function(self)
		self:record(0, "action:skipBlind")
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			if ctx.is_pov then G.FUNCS.skip_blind({ UIBox = G.blind_select }) end
		end
	end,
}

-------------------------------------------------------------------------------
-- The single, shared hook installation -- one wrap per vanilla function.
-------------------------------------------------------------------------------

local ease_dollars_ref = ease_dollars
function ease_dollars(mod, instant)
	if RLOG.is_active() then MPAPI.RLOGCodes.money_delta:write(mod) end
	return ease_dollars_ref(mod, instant)
end

local sell_card_ref = Card.sell_card
function Card:sell_card()
	if self.ability and self.ability.name and RLOG.is_active() then
		local human = string.format("action:soldCard,card:%s", self.ability.name)
		local area = RLOG.area_enum(self.area)
		local idx = RLOG.index_in_area(self)
		local ref = RLOG.card_ref(self)
		if area and idx then MPAPI.RLOGCodes.sell:write(area, idx, ref, human) end
	end
	return sell_card_ref(self)
end

local cash_out_ref = G.FUNCS.cash_out
function G.FUNCS.cash_out(e)
	if RLOG.is_active() then MPAPI.RLOGCodes.cashout:write() end
	return cash_out_ref(e)
end

local reroll_shop_ref = G.FUNCS.reroll_shop
function G.FUNCS.reroll_shop(e)
	if RLOG.is_active() then
		MPAPI.RLOGCodes.reroll:write(string.format("action:rerollShop,cost:%s", G.GAME.current_round.reroll_cost))
	end
	return reroll_shop_ref(e)
end

local buy_from_shop_ref = G.FUNCS.buy_from_shop
function G.FUNCS.buy_from_shop(e)
	local c1 = e.config.ref_table
	if c1 and c1:is(Card) and RLOG.is_active() then
		local human = string.format("action:boughtCardFromShop,card:%s,cost:%s", c1.ability.name, c1.cost)
		local area = RLOG.area_enum(c1.area)
		local idx = RLOG.index_in_area(c1)
		if area and idx then
			local key = "buy"
			local set = c1.ability and c1.ability.set
			if set == "Booster" then
				key = "open_pack"
			elseif set == "Voucher" then
				key = "voucher"
			end
			local ref = RLOG.card_ref(c1)
			MPAPI.RLOGCodes[key]:write(area, idx, ref, c1.cost, human)
		end
	end
	return buy_from_shop_ref(e)
end

local use_card_ref = G.FUNCS.use_card
function G.FUNCS.use_card(e, mute, nosave)
	local card = e.config and e.config.ref_table
	if card and card.ability and card.ability.name and RLOG.is_active() then
		local human = string.format("action:usedCard,card:%s", card.ability.name)
		if card.area == (G and G.pack_cards) then
			local idx = RLOG.index_in_area(card, G.pack_cards)
			if idx then
				local targets = RLOG.highlighted_hand_indices()
				local ref = RLOG.card_ref(card)
				local target_refs = RLOG.card_refs(targets)
				MPAPI.RLOGCodes.pack_pick:write(idx, targets, ref, target_refs, human)
			end
		else
			local idx = RLOG.index_in_area(card)
			if idx then
				local targets = RLOG.highlighted_hand_indices()
				local ref = RLOG.card_ref(card)
				local target_refs = RLOG.card_refs(targets)
				MPAPI.RLOGCodes.use:write(idx, targets, ref, target_refs, human)
			end
		end
	end
	return use_card_ref(e, mute, nosave)
end

if G.FUNCS.skip_booster then
	local skip_booster_ref = G.FUNCS.skip_booster
	function G.FUNCS.skip_booster(e)
		if RLOG.is_active() then
			local refs = {}
			if G.pack_cards and G.pack_cards.cards then
				for i = 1, #G.pack_cards.cards do
					refs[i] = RLOG.card_ref(G.pack_cards.cards[i])
				end
			end
			MPAPI.RLOGCodes.pack_skip:write(refs)
		end
		return skip_booster_ref(e)
	end
end

local play_cards_ref = G.FUNCS.play_cards_from_highlighted
function G.FUNCS.play_cards_from_highlighted(...)
	local played = RLOG.highlighted_hand_indices()
	local played_refs = RLOG.card_refs(played)
	play_cards_ref(...)
	if #played > 0 and RLOG.is_active() then
		MPAPI.RLOGCodes.play:write(played, played_refs, "action:play,cards:" .. table.concat(played, "."))
	end
end

local discard_cards_ref = G.FUNCS.discard_cards_from_highlighted
function G.FUNCS.discard_cards_from_highlighted(e, is_hook_blind)
	local discarded = (not is_hook_blind) and RLOG.highlighted_hand_indices() or nil
	local discarded_refs = discarded and RLOG.card_refs(discarded) or nil
	discard_cards_ref(e, is_hook_blind)
	if not is_hook_blind and discarded and #discarded > 0 and RLOG.is_active() then
		MPAPI.RLOGCodes.discard:write(discarded, discarded_refs, "action:discard,cards:" .. table.concat(discarded, "."))
	end
end

local select_blind_ref = G.FUNCS.select_blind
function G.FUNCS.select_blind(e)
	select_blind_ref(e)
	if RLOG.is_active() then
		MPAPI.RLOGCodes.select_blind:write(
			string.format("action:selectBlind,blind:%s", tostring(e.config.ref_table.key or e.config.ref_table.name))
		)
	end
end

local skip_blind_ref = G.FUNCS.skip_blind
function G.FUNCS.skip_blind(...)
	skip_blind_ref(...)
	if RLOG.is_active() then MPAPI.RLOGCodes.skip_blind:write() end
end

-- Joker/hand/consumable reordering (drag-drop) -- diffed on update since there
-- is no discrete base-game reorder callback. Debounced until no card in the
-- area is mid-drag.
local function rlog_reorder_area(cardarea)
	if cardarea == G.jokers then return AREA.jokers end
	if cardarea == G.hand then return AREA.hand end
	if cardarea == G.consumeables then return AREA.consumeables end
	return nil
end

local function rlog_area_dragging(cardarea)
	for _, c in ipairs(cardarea.cards) do
		if c.states and c.states.drag and c.states.drag.is then return true end
	end
	return false
end

local cardarea_update_ref = CardArea.update
function CardArea:update(dt)
	cardarea_update_ref(self, dt)

	local area_id = rlog_reorder_area(self)
	if not area_id or not self.cards or #self.cards == 0 then return end
	if not RLOG.is_active() then return end
	if rlog_area_dragging(self) then return end

	local cur = {}
	for i = 1, #self.cards do
		cur[i] = self.cards[i].sort_id
	end
	local prev = self._rlog_order
	self._rlog_order = cur

	if prev and #prev == #cur then
		local perm = RLOG.reorder_permutation(prev, self.cards)
		if perm then
			local moved = {}
			for j = 1, #perm do
				if perm[j] ~= j then
					moved[#moved + 1] = { RLOG.card_ref(self.cards[j]), perm[j], j }
				end
			end
			MPAPI.RLOGCodes.reorder:write(area_id, perm, moved, "action:reorder,area:" .. area_id)
		end
	end
end
