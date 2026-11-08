-- Lengths and cuts count UTF-8 characters, not bytes: a byte cut can split a
-- multi-byte character, and drawing the result crashes LOVE's text renderer.
-- (LuaJIT has no utf8 library; this pattern matches one encoded character.)
local UTF8_CHAR = '[%z\1-\127\194-\244][\128-\191]*'

local function char_len(s)
	local n = 0
	for _ in s:gmatch(UTF8_CHAR) do
		n = n + 1
	end
	return n
end

-- The first n characters of s, and the rest.
local function char_split(s, n)
	local head, i = {}, 0
	for c in s:gmatch(UTF8_CHAR) do
		if i == n then break end
		i = i + 1
		head[i] = c
	end
	local first = table.concat(head)
	return first, s:sub(#first + 1)
end

-- The code point of one UTF-8 character (as matched by UTF8_CHAR).
local function code_point(c)
	local b = c:byte(1)
	if #c == 1 then return b end
	local cp = b % (2 ^ (7 - #c))
	for i = 2, #c do
		cp = cp * 64 + c:byte(i) % 64
	end
	return cp
end

-- Styled letters that sit outside the Mathematical Alphanumeric block (its
-- reserved holes point here, e.g. fraktur C is U+212D).
local LETTERLIKE = {
	[0x2102] = 'C', [0x210A] = 'g', [0x210B] = 'H', [0x210C] = 'H', [0x210D] = 'H', [0x210E] = 'h',
	[0x2110] = 'I', [0x2111] = 'I', [0x2112] = 'L', [0x2115] = 'N', [0x2119] = 'P', [0x211A] = 'Q',
	[0x211B] = 'R', [0x211C] = 'R', [0x211D] = 'R', [0x2124] = 'Z', [0x2128] = 'Z', [0x212C] = 'B',
	[0x212D] = 'C', [0x212F] = 'e', [0x2130] = 'E', [0x2131] = 'F', [0x2133] = 'M', [0x2134] = 'o',
}

-- The plain ASCII letter or digit a styled one stands for, or nil.
local function plain_char(cp)
	if cp >= 0x1D400 and cp <= 0x1D6A3 then -- bold, italic, script, fraktur, double-struck... A-Z a-z
		local i = (cp - 0x1D400) % 52
		return i < 26 and string.char(65 + i) or string.char(97 + i - 26)
	elseif cp == 0x1D6A4 then
		return 'i'
	elseif cp == 0x1D6A5 then
		return 'j'
	elseif cp >= 0x1D7CE and cp <= 0x1D7FF then -- styled digits
		return string.char(48 + (cp - 0x1D7CE) % 10)
	elseif cp >= 0xFF01 and cp <= 0xFF5E then -- fullwidth ASCII
		return string.char(cp - 0xFEE0)
	elseif cp == 0x3000 then -- ideographic space
		return ' '
	end
	return LETTERLIKE[cp]
end

-- s with styled Unicode letters and digits (Mathematical Alphanumeric
-- Symbols, fullwidth forms) turned into the plain ones they stand for:
-- Balatro's pixel font has no glyphs for them, so a name written in them
-- draws as blank space. Everything else is kept as is.
MPAPI.plain_letters = function(s)
	if type(s) ~= 'string' or not s:find('[\194-\244]') then
		return s
	end
	return (s:gsub(UTF8_CHAR, function(c)
		return #c > 1 and plain_char(code_point(c)) or nil
	end))
end

-- Takes a string and max length (in characters)
-- Returns the string if its length is <= max
-- Returns a substring with ... at the end that is exactly max long
MPAPI.truncate = function(s, max)
	if not s or char_len(s) <= max then
		return s
	end
	return (char_split(s, max - 3)) .. '...'
end

-- Steam and Discord both cap names at 32 characters; the UI shrinks a long
-- name to fit its box, so only a longer one (from elsewhere) gets ...
MPAPI.NAME_MAX_CHARS = 32

-- A player's name as shown in the UI: styled letters folded, cut at 32.
MPAPI.format_name = function(s)
	return MPAPI.truncate(MPAPI.plain_letters(s), MPAPI.NAME_MAX_CHARS)
end

-- A name as one line (up to 20 characters, which fit a button at full size)
-- or two balanced lines, broken at a space when one fits, else in the middle.
MPAPI.name_lines = function(s)
	s = tostring(s or '')
	local n = char_len(s)
	if n <= 20 then
		return { s }
	end
	for width = math.ceil(n / 2), 20 do
		local lines = MPAPI.wrap_words(s, width, 3)
		if #lines <= 2 then
			return lines
		end
	end
	local head, tail = char_split(s, math.ceil(n / 2))
	return { head, (tail:gsub('^%s+', '')) }
end

-- Splits s into lines of at most `width` characters, broken at spaces (a word
-- longer than `width` is cut). At most `max_lines` lines: the last one ends in
-- ... when text was left over.
MPAPI.wrap_words = function(s, width, max_lines)
	local lines = {}
	local line = ''
	for word in tostring(s or ''):gmatch('%S+') do
		while char_len(word) > width do
			if line ~= '' then
				lines[#lines + 1] = line
				line = ''
			end
			lines[#lines + 1], word = char_split(word, width)
		end
		if line == '' then
			line = word
		elseif char_len(line) + 1 + char_len(word) <= width then
			line = line .. ' ' .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if line ~= '' then
		lines[#lines + 1] = line
	end
	if #lines > max_lines then
		local last = lines[max_lines]
		for i = #lines, max_lines, -1 do
			lines[i] = nil
		end
		lines[max_lines] = (char_split(last, width - 3)) .. '...'
	end
	return lines
end
