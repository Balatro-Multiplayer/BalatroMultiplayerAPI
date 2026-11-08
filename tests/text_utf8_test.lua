-- Contract test: MPAPI.truncate and MPAPI.wrap_words count characters, not
-- bytes, so a cut never splits a multi-byte UTF-8 character (a split one made
-- the main menu crash with "UTF-8 decoding error" for a player whose display
-- name was Unicode math letters). Run from the MPAPI repository root:
-- luajit tests/text_utf8_test.lua
MPAPI = {}
dofile('lib/text.lua')

local checks = 0
local function eq(got, want, what)
	checks = checks + 1
	assert(got == want, what .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

-- Valid UTF-8 (Lua 5.1 has no utf8 library: lead byte, then its continuation bytes).
local function valid_utf8(s)
	local i, n = 1, #s
	while i <= n do
		local b = s:byte(i)
		local extra = b < 0x80 and 0 or (b >= 0xC2 and b <= 0xDF) and 1 or (b >= 0xE0 and b <= 0xEF) and 2
			or (b >= 0xF0 and b <= 0xF4) and 3 or nil
		if not extra or i + extra > n then return false end
		for k = 1, extra do
			local c = s:byte(i + k)
			if c < 0x80 or c > 0xBF then return false end
		end
		i = i + extra + 1
	end
	return true
end

-- ASCII keeps today's behaviour.
eq(MPAPI.truncate('short', 20), 'short', 'ascii under the limit')
eq(MPAPI.truncate('abcdefghijklmnopqrstuvwxyz', 20), 'abcdefghijklmnopq...', 'ascii over the limit')
eq(MPAPI.truncate(nil, 20), nil, 'nil')

-- The reporter's name: 7 four-byte math letters plus a 3-byte bullet = 31 bytes, 8 characters.
local name = '𝕹𝖔𝖔𝖋𝖈𝖎𝖚•'
eq(MPAPI.truncate(name, 20), name, 'an 8-character name fits in 20 characters')
eq(valid_utf8(MPAPI.truncate(name, 20)), true, 'reporter name stays valid UTF-8')

local long = string.rep('𝕹', 25)
local cut = MPAPI.truncate(long, 20)
eq(cut, string.rep('𝕹', 17) .. '...', 'cuts after 17 whole characters')
eq(valid_utf8(cut), true, 'long 4-byte name stays valid UTF-8')

for max = 4, 20 do
	eq(valid_utf8(MPAPI.truncate('é' .. string.rep('ñ', 30), max)), true, 'two-byte cut at ' .. max)
end

-- wrap_words: a long word is cut on whole characters, and the overflow line too.
local lines = MPAPI.wrap_words(string.rep('𝕹', 12) .. ' ok', 5, 2)
eq(#lines, 2, 'wrap line count')
eq(lines[1], string.rep('𝕹', 5), 'wrap first line is 5 characters')
eq(lines[2], '𝕹𝕹...', 'wrap overflow line ends in ...')
for _, l in ipairs(lines) do
	eq(valid_utf8(l), true, 'wrapped line valid UTF-8')
end
eq(table.concat(MPAPI.wrap_words('héllo wörld', 11, 2), '|'), 'héllo wörld', 'accented words fit by characters')

print('ok   ' .. checks .. ' checks')
