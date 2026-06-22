-- Copies a table including internal references
MPAPI.shallow_copy = function(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

MPAPI.json_encode = function(tbl)
	if json and json.encode then
		return json.encode(tbl)
	end
	local j = require('json')
	return j.encode(tbl)
end

MPAPI.json_decode = function(str)
	if json and json.decode then
		return json.decode(str)
	end
	local j = require('json')
	return j.decode(str)
end

MPAPI.generate_id = function()
	return string.format('%x%x', os.time(), math.random(0, 0xFFFFFF))
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
