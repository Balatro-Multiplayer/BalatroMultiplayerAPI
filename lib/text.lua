function MPAPI.truncate(s, max)
	if not s or #s <= max then
		return s
	end
	return s:sub(1, max - 3) .. '...'
end
