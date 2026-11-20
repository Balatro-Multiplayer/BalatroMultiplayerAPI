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
--
-- A shop loaded from a save (a Run save taken at the shop) skips `starting_shop`: vanilla puts the
-- saved cards back from G.load_shop_jokers, G.load_shop_vouchers and G.load_shop_booster instead
-- and clears each one as it goes. That shop is built once all three are cleared.
MPAPI.playback = MPAPI.playback or {}
MPAPI._internal.playback = MPAPI._internal.playback or {}

-- The shop UIBox that got its starting cards. A new shop visit makes a new UIBox, so no reset is needed.
local built_shop = nil
-- The shop UIBox that was made while saved shop cards waited to be loaded into it.
local loading_shop = nil

-- Marks the current shop as built. The hook below calls it on `starting_shop`.
function MPAPI.playback.mark_shop_built()
	built_shop = G.shop
end

if not MPAPI._internal.playback.shop_built_hooked then
	MPAPI._internal.playback.shop_built_hooked = true
	local calculate_context_ref = SMODS.calculate_context
	function SMODS.calculate_context(context, ...)
		if type(context) == 'table' and context.starting_shop then
			MPAPI.playback.mark_shop_built()
		end
		return calculate_context_ref(context, ...)
	end
	if Game and Game.update_shop then
		local update_shop_ref = Game.update_shop
		function Game:update_shop(dt)
			-- Vanilla makes the UIBox in this call when there is none, and loads the saved cards into
			-- it only then (`shop_exists`).
			local loading = not G.STATE_COMPLETE and not G.shop and (G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster) ~= nil
			local result = update_shop_ref(self, dt)
			if loading then
				loading_shop = G.shop
			end
			return result
		end
	end
end

local function loaded_from_save()
	return G.shop == loading_shop and G.load_shop_jokers == nil and G.load_shop_vouchers == nil and G.load_shop_booster == nil
end

-- True once the current shop has its starting jokers, vouchers and packs, drawn or loaded.
function MPAPI.playback.shop_is_built()
	return G.shop ~= nil and (G.shop == built_shop or loaded_from_save()) and G.shop_jokers ~= nil and G.shop_jokers.cards ~= nil
end
