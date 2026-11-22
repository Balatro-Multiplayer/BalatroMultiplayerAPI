-- Contract test for lib/text.lua.
local T = dofile('tests/support.lua')
local eq = T.eq
MPAPI = {}
dofile('lib/text.lua')

-- MPAPI.format_name keeps every Steam or Discord name (both cap at 32 characters) whole, so the
-- UI shrinks it to fit instead of showing ...
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

-- MPAPI.plain_letters turns styled Unicode letters and digits (which Balatro's pixel font cannot
-- draw, so a name written in them showed as a blank button) into the plain ones, and leaves
-- everything else alone.
-- The reporter's name: bold fraktur letters and a bullet (no plain form, kept).
eq(MPAPI.plain_letters('𝕹𝖔𝖔𝖋𝖈𝖎𝖚•'), 'Noofciu•', 'reporter name')

-- One sample per style block, upper and lower case.
eq(MPAPI.plain_letters('𝐀𝐳'), 'Az', 'bold')
eq(MPAPI.plain_letters('𝘈𝘻'), 'Az', 'sans italic')
eq(MPAPI.plain_letters('𝒜𝓏'), 'Az', 'script')
eq(MPAPI.plain_letters('𝔸𝕫'), 'Az', 'double-struck')
eq(MPAPI.plain_letters('𝚊𝚉'), 'aZ', 'monospace (last letter block)')
eq(MPAPI.plain_letters('𝚤𝚥'), 'ij', 'dotless i and j')

-- Letters that live in the Letterlike block instead (holes in the math block).
eq(MPAPI.plain_letters('ℭℌℑℜℨ'), 'CHIRZ', 'fraktur capitals')
eq(MPAPI.plain_letters('ℂℕℝℤ'), 'CNRZ', 'double-struck capitals')
eq(MPAPI.plain_letters('ℎℯℴ'), 'heo', 'italic h, script e and o')

-- Digits, fullwidth forms, the ideographic space.
eq(MPAPI.plain_letters('𝟎𝟗𝟘𝟿'), '0909', 'styled digits')
eq(MPAPI.plain_letters('ＡＢＣ１２３！～'), 'ABC123!~', 'fullwidth')
eq(MPAPI.plain_letters('a　b'), 'a b', 'ideographic space')

-- Left alone: plain text, accents, other scripts, emoji, non-strings.
eq(MPAPI.plain_letters('Player_01'), 'Player_01', 'ascii')
eq(MPAPI.plain_letters('Jérôme Ñandú'), 'Jérôme Ñandú', 'accents')
eq(MPAPI.plain_letters('Привет 日本'), 'Привет 日本', 'cyrillic and cjk')
eq(MPAPI.plain_letters('a😀b'), 'a😀b', 'emoji')
eq(MPAPI.plain_letters(nil), nil, 'nil')
eq(MPAPI.plain_letters(''), '', 'empty')

-- Folding first, then cutting: the cut counts the plain letters.
eq(MPAPI.truncate(MPAPI.plain_letters(string.rep('𝕹', 25)), 20), string.rep('N', 17) .. '...', 'fold then truncate')

-- MPAPI.truncate and MPAPI.wrap_words count characters, not bytes, so a cut never splits a
-- multi-byte UTF-8 character (a split one made the main menu crash with "UTF-8 decoding error"
-- for a player whose display name was Unicode math letters).
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

T.done('text_test')
