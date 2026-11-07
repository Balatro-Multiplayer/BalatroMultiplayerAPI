--[[
  Card-save validation test: a payload from the opponent must not be able to put a wrong-typed
  field into a card's ability (the h_size = "abc" crash).

  Run from the repo root:
    luajit tests/card_save_validation_test.lua
]]

MPAPI = { sendWarnMessage = function() end }
G = {
	jokers = {},
	consumeables = {},
	P_CENTERS = {
		j_joker = { set = "Joker", config = { mult = 4 } },
		j_x = { set = "Joker", config = { extra = { rounds = 2, name = "a" } } },
		c_fool = { set = "Tarot", consumeable = true, config = {} },
	},
}
STR_PACK, STR_UNPACK = function() end, function() end
love = { data = {} }
dofile("api/synced/serialize.lua")

local function save(center, ability)
	return { save_fields = { center = center }, ability = ability }
end
local fails = 0
local function check(name, got, want)
	if got ~= want then
		fails = fails + 1
		print("FAIL " .. name)
	end
end
local v = MPAPI.validate_card_save

check("valid joker", v(save("j_joker", { mult = 4, h_size = 0 }), G.jokers), true)
check("string h_size", v(save("j_joker", { mult = 4, h_size = "abcd" }), G.jokers), false)
check("nan mult", v(save("j_joker", { mult = 0 / 0 }), G.jokers), false)
check("config type mismatch", v(save("j_joker", { mult = "4" }), G.jokers), false)
check("nested ok", v(save("j_x", { extra = { rounds = 1, name = "b" } }), G.jokers), true)
check("nested mismatch", v(save("j_x", { extra = { rounds = {}, name = "b" } }), G.jokers), false)
check("missing extra", v(save("j_x", {}), G.jokers), false)
check("unknown center", v(save("j_nope", {}), G.jokers), false)
check("consumable into jokers", v(save("c_fool", {}), G.jokers), false)
check("joker into consumables", v(save("j_joker", { mult = 4 }), G.consumeables), false)
check("function value", v(save("j_joker", { mult = 4, f = print }), G.jokers), false)
check("not a table", v("x", G.jokers), false)

if fails > 0 then os.exit(1) end
print("ok")
