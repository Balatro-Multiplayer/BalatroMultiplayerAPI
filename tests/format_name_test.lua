-- Contract test: MPAPI.format_name keeps every Steam or Discord name (both cap
-- at 32 characters) whole, so the UI shrinks it to fit instead of showing ...
-- Run from the MPAPI repository root: luajit tests/format_name_test.lua
MPAPI = {}
dofile('lib/text.lua')

local checks = 0
local function eq(got, want, what)
	checks = checks + 1
	assert(got == want, what .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

local n32 = string.rep('a', 32)
eq(MPAPI.format_name('Alice'), 'Alice', 'short name unchanged')
eq(MPAPI.format_name(n32), n32, 'a 32-character name is kept whole')
eq(MPAPI.format_name(n32 .. 'b'), string.rep('a', 29) .. '...', 'a 33-character name is cut to 32')
eq(MPAPI.format_name(string.rep('𝕹', 32)), string.rep('N', 32), 'styled letters fold, then count as plain')
eq(MPAPI.format_name(nil), nil, 'nil')

-- name_lines: one line up to 20 characters, else two balanced lines.
local function lines(s)
	return table.concat(MPAPI.name_lines(s), '|')
end
eq(lines('Alice'), 'Alice', 'short name is one line')
eq(lines(string.rep('a', 20)), string.rep('a', 20), '20 characters is one line')
eq(lines(string.rep('a', 32)), string.rep('a', 16) .. '|' .. string.rep('a', 16), 'no spaces: split in half')
eq(lines('The Quick Brown Fox Jumps Over'), 'The Quick Brown|Fox Jumps Over', 'breaks at a space')
eq(lines('a ' .. string.rep('b', 30)), 'a ' .. string.rep('b', 14) .. '|' .. string.rep('b', 16), 'no space fits: split in half')
eq(lines(string.rep('𝕹', 32)), string.rep('𝕹', 16) .. '|' .. string.rep('𝕹', 16), 'splits on whole characters')

print('ok   ' .. checks .. ' checks')
