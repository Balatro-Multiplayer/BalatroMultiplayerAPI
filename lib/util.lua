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

-- Plain-string gzip+base64 decode, for payloads that are already strings (the
-- replay carbon log -- see api/playback/timeline.lua) rather than a Lua table.
-- MPAPI.decode (api/synced/serialize.lua) does a similar-looking two-step
-- love.data.decode/decompress, but its remaining step (STR_UNPACK_CHECKED)
-- expects a `return {...}` Lua-table-literal string, not a JSON payload, so
-- it isn't reusable here as-is -- this is the same plain codec PvP's own
-- lib/serialization.lua carries (PVP.UTILS.decompress_str), duplicated here
-- because MPAPI's own playback module must not depend on PvP.
MPAPI.decompress_str = function(str)
	if type(str) ~= 'string' then return nil, 'expected string payload' end
	local ok, decoded = pcall(love.data.decode, 'string', 'base64', str)
	if not ok then return nil, decoded end
	local ok2, decompressed = pcall(love.data.decompress, 'string', 'gzip', decoded)
	if not ok2 then return nil, decompressed end
	return decompressed
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
