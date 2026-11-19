-- Contract test: MPAPI.plain_letters turns styled Unicode letters and digits
-- (which Balatro's pixel font cannot draw, so a name written in them showed
-- as a blank button) into the plain ones, and leaves everything else alone.
-- Run from the MPAPI repository root: luajit tests/plain_letters_test.lua
MPAPI = {}
dofile('lib/text.lua')

local checks = 0
local function eq(got, want, what)
	checks = checks + 1
	assert(got == want, what .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

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

print('ok   ' .. checks .. ' checks')
