-- Copies a table including internal references
MPAPI.shallow_copy = function(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

-- Merges two tables with unique values, preserves order
MPAPI.merge_unique = function(a, b)
	local seen = {}
	local out = {}
	for _, v in ipairs(a) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	for _, v in ipairs(b) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	return out
end
