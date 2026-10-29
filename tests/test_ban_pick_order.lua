-- Contract test for the optional tile order of the Ban-Pick Draft. Run from the
-- MPAPI repository root: luajit tests/test_ban_pick_order.lua
--
-- The server shuffles the pool, so the tiles used to show in a random order.
-- A config may now set tile_order(a, b); the screen then draws a sorted copy of
-- the pool. Bans and picks still go by the tile's key, so sorting must never
-- change which key a tile has. Without a comparator the pool is untouched.
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = {}
G = { FUNCS = {} }
dofile('api/ban_pick.lua')
local BP = MPAPI.BanPick

check(type(BP._ordered_pool) == 'function', 'ordered_pool is exposed for tests')

-- Tiles as they come off the wire for a config whose items carry an id:
-- key is the tile's tracking id, art the deck back, stake rides along.
local function wire(deck, stake)
	return { key = deck .. '@' .. stake, art = deck, stake = stake }
end
local function by_stake_then_deck(a, b)
	if a.stake ~= b.stake then
		return a.stake < b.stake
	end
	return a.key < b.key
end

local pool = {
	wire('b_plasma', 8),
	wire('b_red', 4),
	wire('b_blue', 1),
	wire('b_red', 1),
	wire('b_green', 4),
	wire('b_black', 3),
}

-- No comparator: the very same table comes back, server order kept.
check(BP._ordered_pool(pool, nil) == pool, 'no comparator leaves the pool as is')

local sorted = BP._ordered_pool(pool, by_stake_then_deck)
local want = { 'b_blue@1', 'b_red@1', 'b_black@3', 'b_green@4', 'b_red@4', 'b_plasma@8' }
check(#sorted == #want, 'the sorted copy has every tile')
for i, key in ipairs(want) do
	check(sorted[i].key == key, 'tile ' .. i .. ' is ' .. key .. ', got ' .. tostring(sorted[i].key))
end

-- The server's pool is not reordered or edited.
check(pool[1].key == 'b_plasma@8' and pool[2].key == 'b_red@4' and #pool == 6, 'the server pool keeps its order')

-- The comparator sees the config's shape (id + key), not the wire shape.
local seen
BP._ordered_pool({ wire('b_red', 4), wire('b_blue', 1) }, function(a, b)
	seen = seen or a
	return a.stake < b.stake
end)
check(seen.id == seen.key .. '@' .. seen.stake and seen.key:sub(1, 2) == 'b_' and seen.art == nil, 'comparator gets { id, key, stake }')

-- Equal tiles keep the server's order (stable).
local ties = { wire('b_red', 4), wire('b_blue', 4), wire('b_green', 4) }
local flat = BP._ordered_pool(ties, function(a, b)
	return a.stake < b.stake
end)
check(flat[1].key == 'b_red@4' and flat[2].key == 'b_blue@4' and flat[3].key == 'b_green@4', 'ties keep the server order')

-- A ban or pick still targets the same tile: selection works on keys read from
-- the sorted pool, and every key maps to the same tile as in the server's pool.
local state = { pool = sorted, banned = { ['b_red@4'] = true }, step = { action = 'ban', count = 2 }, remaining = 2 }
local kept = BP._selection.prune({ 'b_red@4', 'b_black@3', 'b_plasma@8' }, state)
check(#kept == 2 and kept[1] == 'b_black@3' and kept[2] == 'b_plasma@8', 'a banned key is dropped, the others still resolve')
local by_key = {}
for _, tile in ipairs(pool) do
	by_key[tile.key] = tile
end
for _, tile in ipairs(sorted) do
	check(by_key[tile.key] == tile, tile.key .. ' is the same tile in both orders')
end

print('ban_pick order: ' .. checks .. ' checks passed')
