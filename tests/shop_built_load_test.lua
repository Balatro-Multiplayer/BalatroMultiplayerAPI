-- A shop loaded from a save counts as built once its saved cards are in. Vanilla skips the
-- `starting_shop` context for it (nosave_shop) and loads G.load_shop_jokers, G.load_shop_vouchers
-- and G.load_shop_booster instead, clearing each. A drawn shop is still built only on
-- `starting_shop`. Run from the MPAPI repository root: luajit tests/shop_built_load_test.lua
-- (an optional argument names another shop_built.lua to load).
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

SMODS = { calculate_context = function() end }
G = { STATE_COMPLETE = false }
-- Vanilla's first update_shop call of a visit makes the UIBox when there is none.
Game = {
	update_shop = function()
		if not G.STATE_COMPLETE then
			G.shop = G.shop or { name = 'shop UIBox' }
			G.shop_jokers = { cards = {} }
			G.STATE_COMPLETE = true
		end
	end,
}
MPAPI = { _internal = {} }
dofile(arg and arg[1] or 'api/playback/shop_built.lua')
local P = MPAPI.playback

-- A shop loaded from a save.
G.load_shop_jokers, G.load_shop_vouchers, G.load_shop_booster = {}, {}, {}
Game:update_shop(0.1)
Game:update_shop(0.1)
check(P.shop_is_built() == false, 'not built while the saved cards wait')
G.load_shop_jokers = nil
G.load_shop_vouchers = nil
check(P.shop_is_built() == false, 'not built until the packs are loaded too')
G.load_shop_booster = nil
check(P.shop_is_built() == true, 'built once all three saved areas are loaded')

-- The next visit draws its cards: built only on starting_shop.
G.shop, G.STATE_COMPLETE = nil, false
Game:update_shop(0.1)
check(P.shop_is_built() == false, 'a drawn shop is not built before starting_shop')
SMODS.calculate_context({ starting_shop = true })
check(P.shop_is_built() == true, 'a drawn shop is built on starting_shop')

-- A visit whose UIBox already existed loads nothing and is not taken for a loaded shop.
G.shop, G.STATE_COMPLETE = nil, false
Game:update_shop(0.1)
G.STATE_COMPLETE = false
G.load_shop_jokers = {}
Game:update_shop(0.1)
G.load_shop_jokers = nil
check(P.shop_is_built() == false, 'a shop that existed before the load data is not built by it')

print(string.format('shop_built_load_test: %d checks passed', checks))
