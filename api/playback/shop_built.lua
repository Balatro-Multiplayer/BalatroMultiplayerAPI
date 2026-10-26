-- Tells a replay when the shop has its starting cards.
--
-- Vanilla builds a shop in two steps (Game:update_shop). The next frame after G.STATE becomes SHOP
-- it creates the UIBox, so G.shop_jokers exists but holds no card. The starting jokers, vouchers
-- and packs are drawn later, in an event that waits for the shop to slide in. That event ends with
-- the `starting_shop` context.
--
-- A replayed buy found no card in the empty area and bought nothing. A replayed reroll ran first,
-- so its draws came before the starting draws, and the shop that followed was not the recorded one.
-- An area that exists is not enough: the replay has to wait for `starting_shop`.
MPAPI.playback = MPAPI.playback or {}

-- The shop UIBox that got its starting cards. A new shop visit makes a new UIBox, so no reset is needed.
local built_shop = nil

-- Marks the current shop as built. The hook below calls it on `starting_shop`.
function MPAPI.playback.mark_shop_built()
	built_shop = G.shop
end

if not MPAPI._playback_shop_built_hooked then
	MPAPI._playback_shop_built_hooked = true
	local calculate_context_ref = SMODS.calculate_context
	function SMODS.calculate_context(context, ...)
		if type(context) == 'table' and context.starting_shop then
			MPAPI.playback.mark_shop_built()
		end
		return calculate_context_ref(context, ...)
	end
end

-- True once the current shop has its starting jokers, vouchers and packs.
function MPAPI.playback.shop_is_built()
	return G.shop ~= nil and G.shop == built_shop and G.shop_jokers ~= nil and G.shop_jokers.cards ~= nil
end
