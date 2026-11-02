-- Contract test: the deck tile tooltip holds only tables in its node lists,
-- with or without a tile note. A false in a node list crashes the engine's
-- UIBox build. Run from the MPAPI repository root:
-- luajit tests/ban_pick_tooltip_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local file = assert(io.open('api/ban_pick.lua'))
local source = file:read('*a')
file:close()
-- Reach the local deck_tile builder.
source = source:gsub('local function build_banpick_contents', 'MPAPI.BanPick._deck_tile = deck_tile\nlocal function build_banpick_contents', 1)

MPAPI = {}
G = {
	FUNCS = {},
	UIT = { C = 1, R = 2, T = 3, O = 4, ROOT = 7 },
	C = setmetatable({}, { __index = function() return { 1, 1, 1, 1 } end }),
	ROOM = { T = { w = 10 } },
	CARD_W = 1,
	CARD_H = 1,
	P_CENTERS = { b_red = { name = 'x' } },
}
SMODS = { create_mod_badges = function() end }
Back = function()
	return { get_name = function() return 'Red' end, generate_UI = function() return {} end }
end
DynaText = function() return {} end
UIBox = function() return {} end
Node = { hover = function() end }
local card
Card = function(_, _, _, _, _, center)
	card = { T = { x = 1 }, config = { center = center }, align_h_popup = function() return {} end }
	return card
end
local area = { T = { x = 0, y = 0, w = 1 }, emplace = function() end }
assert(loadstring(source, 'ban_pick'))()

-- Same traversal as engine/ui.lua: every child must be a table.
local function walk(node)
	check(type(node) == 'table', 'a tooltip node list holds a ' .. type(node))
	if node.nodes then
		for _, child in pairs(node.nodes) do
			walk(child)
		end
	end
end

for _, note in ipairs({ 'none', 'Gold' }) do
	MPAPI.BanPick._deck_tile({ key = 'b_red' }, false, area)
	card.mp_tile_note = note ~= 'none' and note or nil
	card:hover()
	walk(card.config.h_popup)
end

print('ok ' .. checks .. ' checks')
