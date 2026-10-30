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

-- A broken comparator degrades to server order instead of raising mid-build.
local always = BP._ordered_pool(pool, function()
	return true
end)
check(#always == #pool and always[1].key == pool[1].key and always[6].key == pool[6].key, 'a comparator that says true both ways keeps the server order')
check(BP._ordered_pool(pool, true) == pool, 'a tile_order that is not a function leaves the pool as is')

-- A ban or pick still targets the same tile: selection works on keys read from
-- the sorted pool, and every key maps to the same tile as in the server's pool.
local state = { pool = sorted, banned = { ['b_red@4'] = true }, step = { action = 'ban', count = 2 }, remaining = 2 }
local kept = BP._selection.prune({ 'b_red@4', 'b_black@3', 'b_plasma@8' }, state)
check(#kept == 2 and kept[1] == 'b_black@3' and kept[2] == 'b_plasma@8', 'a banned key is dropped, the others still resolve')
-- Field by field, against a snapshot of what the server sent (copies, so a
-- tile that was swapped for another one cannot pass by identity): the tile at
-- every sorted position is the server's tile for that key, with its art and
-- stake, and sorting by index instead of by tile would fail here.
local snapshot = {}
for _, tile in ipairs(pool) do
	snapshot[tile.key] = { key = tile.key, art = tile.art, stake = tile.stake }
end
for i, tile in ipairs(sorted) do
	local held = snapshot[tile.key]
	check(held ~= nil, 'sorted position ' .. i .. ' holds a tile the server sent')
	check(tile.art == held.art and tile.stake == held.stake, tile.key .. ' keeps its art and stake at position ' .. i)
	check(tile.art == tile.key:match('^(.-)@') and tostring(tile.stake) == tile.key:match('@(%d+)$'), tile.key .. ' art and stake agree with its key')
end

-- Ban one key, whatever its sorted position: a selection of that key is dropped.
for banned_key, _ in pairs(snapshot) do
	local view = { pool = sorted, banned = { [banned_key] = true }, step = { action = 'ban', count = 1 }, remaining = 1 }
	check(#BP._selection.prune({ banned_key }, view) == 0, 'a selection of ' .. banned_key .. ' is dropped once it is banned')
end

print('ban_pick order: ' .. checks .. ' checks passed')
