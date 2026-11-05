-- Contract test: the Ban name rule matches the server's. Run from the MPAPI
-- repository root: luajit tests/ban_name_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = {}
local ban_name = dofile('lib/ban_name.lua')

-- The same vectors as packages/types/src/ban-name.test.ts.
local vectors = {
	{ '00000000-0000-0000-0000-000000000000', 'Nebula Four Fingers' },
	{ '11111111-2222-3333-4444-555555555555', 'Nebula Campfire' },
	{ 'a3f1c2d4-5b6e-4f70-8a91-b2c3d4e5f607', 'Magic Devious' },
	{ 'ffffffff-ffff-ffff-ffff-ffffffffffff', 'Nebula Bootstraps' },
	{ '0b9d4a52-77c1-4e0f-9a3d-1c2e3f405162', 'Ghost Burnt' },
}
for _, vector in ipairs(vectors) do
	check(ban_name.name_of(vector[1]) == vector[2], vector[1] .. ' -> ' .. ban_name.name_of(vector[1]))
end

check(ban_name.name_of('A3F1C2D4-5B6E-4F70-8A91-B2C3D4E5F607') == 'Magic Devious', 'case does not matter')
check(#ban_name.decks == 10, 'ten decks')
check(#ban_name.jokers == 149, '149 jokers')

print('ban_name_test: ' .. checks .. ' checks passed')
