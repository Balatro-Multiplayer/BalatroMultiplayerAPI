-- Copies a table including internal references
function MPAPI.shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end
