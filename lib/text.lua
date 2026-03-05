-- Takes a string and max length
-- Returns the string if its length is <= max
-- Returns a substring with ... at the end that is exactly max long
function MPAPI.truncate(s, max)
	if not s or #s <= max then
		return s
	end
	return s:sub(1, max - 3) .. '...'
end
