-- MPAPI.BigScore: score text, the one form every score takes on the wire and in
-- storage.
--
-- A score is the normalized OmegaNum array, entries joined by ',', from
-- array[1] up. array[1] is written in its shortest exact form (up to 17
-- digits, so the double comes back exactly); the higher entries are integers.
-- '100,1' is 10^100. '20,2' is 10^10^20. '12345' is 12345.
--
-- Normalizing and comparing follow OmegaNum.js (`normalize`, `cmp`), never the
-- installed mod's own compare. The twin is BalatroMultiplayerServer
-- packages/types/src/big-score.ts; both are tested with the same vector table.
-- Change both together.
--
-- Value rules: scores are whole numbers (rounded down); a negative score is
-- '0'; a vanilla inf or NaN is the largest double; a Talisman or Amulet
-- Infinity or NaN is TOP, the top value the array limit allows.
--
-- from_game_value looks at the value's type each time it is called, never at
-- load time, because Talisman and Amulet may load before or after MPAPI.

local MAX_SAFE = 9007199254740991
-- The longest array a score may have. It guards against huge messages.
local MAX_ARRAY_LENGTH = 100
-- Longer text than any valid score is refused before it is split.
local MAX_TEXT_LENGTH = 4096
-- Balatro switches from digits to e-notation at this value.
local E_SWITCH_POINT = 100000000000
local LARGEST_DOUBLE = 1.7976931348623157e308

local floor = math.floor
local log10 = math.log10 or function(x) return math.log(x, 10) end
local LOG_MAX_SAFE = log10(MAX_SAFE)

local function top_array()
	local array = {}
	for i = 1, MAX_ARRAY_LENGTH do
		array[i] = MAX_SAFE
	end
	return array
end

-- OmegaNum.js `normalize` for a positive sign. Takes a dense array; returns a
-- new one, or the top array when the result is longer than the limit.
local function normalize_array(input)
	local n = #input
	if n == 0 then return { 0 } end
	if n > MAX_ARRAY_LENGTH then return top_array() end
	local x = {}
	for i = 1, n do
		local e = input[i]
		if e ~= e or e == math.huge or e == -math.huge then return top_array() end
		if i ~= 1 and e ~= floor(e) then e = floor(e) end
		x[i] = e
	end
	local again
	repeat
		again = false
		while #x > 0 and x[#x] == 0 do
			x[#x] = nil
			again = true
		end
		if (x[1] or 0) > MAX_SAFE then
			x[2] = (x[2] or 0) + 1
			x[1] = log10(x[1])
			again = true
		end
		while (x[1] or 0) < LOG_MAX_SAFE and (x[2] or 0) ~= 0 do
			x[1] = 10 ^ x[1]
			x[2] = x[2] - 1
			again = true
		end
		if #x > 2 and (x[2] or 0) == 0 then
			local i = 3
			while (x[i] or 0) == 0 do
				i = i + 1
			end
			x[i - 1] = floor(x[1])
			x[1] = 10 ^ (x[1] - floor(x[1]))
			x[i] = x[i] - 1
			again = true
		end
		for i = 2, #x do
			if x[i] > MAX_SAFE then
				x[i + 1] = (x[i + 1] or 0) + 1
				x[1] = x[i] + 1
				for j = 2, i do
					x[j] = 0
				end
				again = true
			end
		end
		if #x > MAX_ARRAY_LENGTH then return top_array() end
	until not again
	if #x == 0 then return { 0 } end
	if #x == 1 then x[1] = floor(x[1]) end
	return x
end

-- array[1]: an exact integer, or the shortest of 15, 16 and 17 significant
-- digits that reads back as the same double. Never exponent notation.
local function write_first(x)
	if x == floor(x) then return string.format('%.0f', x) end
	for digits = 15, 17 do
		local s = string.format('%.' .. digits .. 'g', x)
		if not s:find('e', 1, true) and tonumber(s) == x then return s end
	end
	return string.format('%.17g', x)
end

local function write_array(array)
	local parts = { write_first(array[1]) }
	for i = 2, #array do
		parts[i] = string.format('%.0f', array[i])
	end
	return table.concat(parts, ',')
end

-- Splits score text into numbers; nil when the text is malformed or the array
-- is longer than the limit.
local function read_array(text)
	if type(text) ~= 'string' or #text == 0 or #text > MAX_TEXT_LENGTH then return nil end
	local array = {}
	local from = 1
	while true do
		local comma = text:find(',', from, true)
		local part = text:sub(from, (comma or #text + 1) - 1)
		local index = #array + 1
		if index > MAX_ARRAY_LENGTH then return nil end
		local ok
		if index == 1 then
			ok = part:match('^%d+$') or part:match('^%d+%.%d+$')
		else
			ok = part:match('^%d+$')
		end
		if not ok or part:match('^0%d') then return nil end
		local value = tonumber(part)
		if not value or value == math.huge then return nil end
		array[index] = value
		if not comma then break end
		from = comma + 1
	end
	return array
end

local TOP = write_array(top_array())

-- A Lua table with possible holes becomes a dense array, or nil when it has no
-- numeric entries. Reads a copy, never the game's own table.
local function dense_copy(source)
	local top = 0
	for key in pairs(source) do
		if type(key) == 'number' and key > top then top = key end
	end
	if top == 0 then return nil end
	if top > MAX_ARRAY_LENGTH then return top_array() end
	local array = {}
	for i = 1, top do
		array[i] = source[i] or 0
	end
	return array
end

local function from_array(source, sign)
	if type(sign) == 'number' and sign < 0 then return '0' end
	local array = dense_copy(source)
	if not array then return '0' end
	return write_array(normalize_array(array))
end

local function from_number(n)
	if n ~= n or n == math.huge then n = LARGEST_DOUBLE end
	if n < 1 then return '0' end
	return write_array(normalize_array({ floor(n) }))
end

-- Amulet holds its array behind get_array() (a value's `.array` is a shared
-- empty table); it can be a LuaJIT cdata. Returns the array and sign, or nil.
local function amulet_parts(x)
	local ok, getter = pcall(function() return x.get_array end)
	if not ok or type(getter) ~= 'function' then return nil end
	local got, array = pcall(getter, x)
	if not got or type(array) ~= 'table' then return nil end
	local sign_ok, sign = pcall(function() return x.sign end)
	return array, sign_ok and sign or 1
end

-- Talisman's old BigNum mode: a mantissa and an exponent, value m * 10^e.
local function from_bignum(m, e)
	if m ~= m or e ~= e or m == math.huge or e == math.huge then return TOP end
	if m <= 0 then return '0' end
	if e < 15 then return from_number(m * 10 ^ e) end
	return write_array(normalize_array({ e + log10(m), 1 }))
end

local function parse_text(text)
	local array = read_array(text)
	if not array then return nil end
	return normalize_array(array)
end

-- A number or a string: a string that is score text is read as score text,
-- else it is read as a plain decimal number, else it is 0.
local function from_string(text)
	local normal = parse_text(text)
	if normal then return write_array(normal) end
	local n = tonumber((text:gsub('^%s+', ''):gsub('%s+$', '')))
	if n then return from_number(n) end
	return '0'
end

local function from_game_value(x)
	local kind = type(x)
	if kind == 'number' then return from_number(x) end
	if kind == 'string' then return from_string(x) end
	if kind ~= 'table' and kind ~= 'cdata' then return '0' end
	local array, sign = amulet_parts(x)
	if array then return from_array(array, sign) end
	if kind == 'table' then
		if type(x.array) == 'table' then return from_array(x.array, x.sign) end
		if type(x.m) == 'number' and type(x.e) == 'number' then return from_bignum(x.m, x.e) end
	end
	return '0'
end

-- -1, 0 or 1 like OmegaNum `cmp`, or nil when either text is malformed.
local function compare(a, b)
	local p = parse_text(a)
	local q = parse_text(b)
	if not p or not q then return nil end
	if #p ~= #q then return #p > #q and 1 or -1 end
	for i = #p, 1, -1 do
		if p[i] > q[i] then return 1 end
		if p[i] < q[i] then return -1 end
	end
	return 0
end

-- --- Display: Balatro notation (the Talisman 'Balatro' notation) ---
-- Mantissas are rounded half up to 3 decimals. A mantissa that rounds to 10
-- becomes 1 with the exponent plus one. Digits come from integer math so both
-- sides print the same text.

local function group_digits(digits)
	local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):gsub(',$', '')
	return grouped:reverse()
end

-- The first 4 significant digits of a whole number, rounded half up by the 5th
-- digit, and the power of ten: value is about m / 1000 * 10^exp.
local function four_digits(whole)
	local digits = string.format('%.0f', floor(whole))
	local m = tonumber(digits:sub(1, 4) .. string.rep('0', 4 - math.min(#digits, 4)))
	local exp = #digits - 1
	if #digits > 4 and digits:byte(5) >= 53 then m = m + 1 end
	if m >= 10000 then
		m = 1000
		exp = exp + 1
	end
	return m, exp
end

local function mantissa_text(m)
	local whole = floor(m / 1000)
	local fraction = string.format('%03d', m % 1000):gsub('0+$', '')
	if fraction == '' then return string.format('%d', whole) end
	return string.format('%d', whole) .. '.' .. fraction
end

-- A mantissa in [1, 10) as thousandths, and the carry into the exponent.
local function round_mantissa(mantissa)
	local m = floor(mantissa * 1000 + 0.5)
	if m >= 10000 then return 1000, 1 end
	return m, 0
end

-- Vanilla number_format for a number in an exponent or array entry.
local function format_entry(num)
	if num >= 1000000 then
		local m, exp = four_digits(num)
		return string.format('%.3f', m / 1000) .. 'e' .. exp
	end
	if num == floor(num) then return group_digits(string.format('%.0f', num)) end
	local places = num >= 100 and 0 or (num >= 10 and 1 or 2)
	local scaled = floor(num * 10 ^ places + 0.5)
	local whole = floor(scaled / 10 ^ places)
	local text = group_digits(string.format('%.0f', whole))
	if places == 0 then return text end
	return text .. '.' .. string.format('%0' .. places .. 'd', scaled - whole * 10 ^ places)
end

local function round_thousandths(num) return floor(num * 1000 + 0.5) / 1000 end

local function display_array(a)
	local count = #a
	if count == 1 then
		if a[1] < E_SWITCH_POINT then return group_digits(string.format('%.0f', a[1])) end
		local m, exp = four_digits(a[1])
		return mantissa_text(m) .. 'e' .. format_entry(exp)
	end
	local first = a[1]
	if count == 2 and a[2] == 1 and first >= 1000000 then
		local exp = floor(log10(first))
		local m, carry = round_mantissa(first / 10 ^ exp)
		return 'e' .. mantissa_text(m) .. 'e' .. format_entry(exp + carry)
	end
	if count == 2 and a[2] <= 8 then
		local exp = floor(first)
		local m, carry = round_mantissa(10 ^ (first - exp))
		return string.rep('e', a[2] - 1) .. mantissa_text(m) .. 'e' .. format_entry(exp + carry)
	end
	if count < 8 then
		local text = 'e' .. format_entry(round_thousandths(first)) .. '#' .. format_entry(a[2])
		for i = 3, count do
			text = text .. '#' .. format_entry(a[i] + 1)
		end
		return text
	end
	return 'e' .. format_entry(round_thousandths(first)) .. '#' .. format_entry(a[count]) .. '##' .. format_entry(count - 2)
end

MPAPI.BigScore = {
	MAX_ARRAY_LENGTH = MAX_ARRAY_LENGTH,
	ZERO = '0',
	TOP = TOP,

	-- Score text of any game value: a plain double, a Talisman OmegaNum or old
	-- BigNum, an Amulet value, or a string.
	from_game_value = from_game_value,

	-- Canonical score text, or nil when the text is malformed.
	normalize = function(text)
		local array = parse_text(text)
		return array and write_array(array) or nil
	end,

	-- -1, 0 or 1, or nil when either text is malformed.
	compare = compare,

	-- Text for people in Balatro notation, or nil when the text is malformed.
	-- Never parsed back.
	display = function(text)
		local array = parse_text(text)
		return array and display_array(array) or nil
	end,
}
