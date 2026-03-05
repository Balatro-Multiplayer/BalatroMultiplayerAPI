-- Copies a table including internal references
MPAPI.shallow_copy = function(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end
