-- Takes a string and max length
-- Returns the string if its length is <= max
-- Returns a substring with ... at the end that is exactly max long
MPAPI.truncate = function(s, max)
	if not s or #s <= max then
		return s
	end
	return s:sub(1, max - 3) .. '...'
end

-- Splits s into lines of at most `width` characters, broken at spaces (a word
-- longer than `width` is cut). At most `max_lines` lines: the last one ends in
-- ... when text was left over.
MPAPI.wrap_words = function(s, width, max_lines)
	local lines = {}
	local line = ''
	for word in tostring(s or ''):gmatch('%S+') do
		while #word > width do
			if line ~= '' then
				lines[#lines + 1] = line
				line = ''
			end
			lines[#lines + 1] = word:sub(1, width)
			word = word:sub(width + 1)
		end
		if line == '' then
			line = word
		elseif #line + 1 + #word <= width then
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
		lines[max_lines] = last:sub(1, width - 3) .. '...'
	end
	return lines
end
