-- Card-area/index/permutation introspection needed to build RLOG_CODE args,
-- promoted out of BalatroMultiplayerPvP/lib/card_utils.lua's PVP.UTILS.*
-- and BalatroMultiplayerSpeed/objects/replay_log/utils.lua's SPDRN.RLOG_UTILS.*
-- (confirmed byte-for-byte identical in logic between the two -- both were
-- independent ports of the same original PvP code) into MPAPI so
-- api/replay/generic_codes.lua's single shared hook file has one copy to call
-- instead of needing a per-mod one. Pure engine introspection, no PvP/SPDRN-
-- specific logic (PVP.UTILS also carries card_to_string/joker_to_string/
-- get_phantom_joker/etc -- those stay PvP-specific, only the area/index/
-- permutation helpers move here).
MPAPI.replay = MPAPI.replay or {}
local RLOG = MPAPI.replay

-- Stable area enum for the carbon replay stream -- the int identifies WHICH
-- CardArea a positional index refers to, independent of card identity/name.
RLOG.AREA = {
	shop_jokers = 1,
	shop_booster = 2,
	shop_vouchers = 3,
	jokers = 4,
	consumeables = 5,
	hand = 6,
	pack_cards = 7,
}

-- Map a live CardArea object to its stable AREA enum int (or nil if unknown).
-- Compared directly against the CardArea globals rather than via a lookup
-- table keyed by them: several are nil depending on game state (G.pack_cards
-- only exists while a booster is open, G.shop_* only in the shop), and a
-- table literal with a nil key throws "table index is nil" -- comparing a
-- live area against a nil global is simply false, so this stays crash-safe.
function RLOG.area_enum(area)
	if not area or not G then return nil end
	if area == G.shop_jokers then return RLOG.AREA.shop_jokers end
	if area == G.shop_booster then return RLOG.AREA.shop_booster end
	if area == G.shop_vouchers then return RLOG.AREA.shop_vouchers end
	if area == G.jokers then return RLOG.AREA.jokers end
	if area == G.consumeables then return RLOG.AREA.consumeables end
	if area == G.hand then return RLOG.AREA.hand end
	if area == G.pack_cards then return RLOG.AREA.pack_cards end
	return nil
end

-- Reverse of area_enum: map a stable AREA enum int back to the live CardArea
-- object it currently refers to (or nil if that area doesn't exist in the
-- current game state, e.g. G.pack_cards outside a booster). Needed on the
-- playback/replay side to turn a recorded area id back into something to
-- index into.
function RLOG.area_object(area_id)
	if not G then return nil end
	if area_id == RLOG.AREA.shop_jokers then return G.shop_jokers end
	if area_id == RLOG.AREA.shop_booster then return G.shop_booster end
	if area_id == RLOG.AREA.shop_vouchers then return G.shop_vouchers end
	if area_id == RLOG.AREA.jokers then return G.jokers end
	if area_id == RLOG.AREA.consumeables then return G.consumeables end
	if area_id == RLOG.AREA.hand then return G.hand end
	if area_id == RLOG.AREA.pack_cards then return G.pack_cards end
	return nil
end

-- 1-based index of a card within its CardArea's card list. `area` defaults to
-- card.area. Returns nil if the card is not found. This positional index is
-- the deterministic reference used by the carbon stream (never card.sort_id,
-- which is a per-run counter that won't match across a re-simulation).
function RLOG.index_in_area(card, area)
	area = area or (card and card.area)
	if not card or not area or not area.cards then return nil end
	for i = 1, #area.cards do
		if area.cards[i] == card then return i end
	end
	return nil
end

-- 1-based G.hand indices of the currently highlighted cards, ascending.
-- Shared by play/discard/consumable-target instrumentation so every hand
-- reference in the carbon stream is a deterministic positional index list.
function RLOG.highlighted_hand_indices()
	local out = {}
	if not (G and G.hand and G.hand.highlighted) then return out end
	for _, c in ipairs(G.hand.highlighted) do
		local i = RLOG.index_in_area(c, G.hand)
		if i then out[#out + 1] = i end
	end
	table.sort(out)
	return out
end

-- Given the previous order (a list of card sort_ids) and the current cards,
-- return the new order expressed as a list of the cards' PREVIOUS 1-based
-- indices -- i.e. the permutation a replay applies to reproduce the reorder.
-- Returns nil if it is not a pure reorder (the card set changed) or if
-- nothing moved. Referencing previous indices (not sort_id) keeps the carbon
-- stream positional and replayable.
function RLOG.reorder_permutation(old_ids, cards)
	if not old_ids or not cards or #cards == 0 or #old_ids ~= #cards then return nil end
	local pos = {}
	for i = 1, #old_ids do
		pos[old_ids[i]] = i
	end
	local perm = {}
	local changed = false
	for j = 1, #cards do
		local oi = pos[cards[j].sort_id]
		if not oi then return nil end
		perm[j] = oi
		if oi ~= j then changed = true end
	end
	if not changed then return nil end
	return perm
end
