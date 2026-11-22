-- Extra keys a mod adds to what its players tell the server when they join its lobby.
-- Nakama join metadata is a map of text to text, and the server reads the mod's keys itself.
-- The keys are asked for at every join, rejoins included, so they are always current.
local key_functions = {}

-- The API's own keys (networking/nakama_lobby.lua): a mod cannot replace them.
local API_KEYS = { modId = true, displayName = true, preferredJoker = true, mods = true, role = true }

-- `base` plus the text keys of `extra`, and the sorted names of the keys left out (not text, or
-- one of the API's own).
local function merged(base, extra)
	local result, left_out = {}, {}
	for key, value in pairs(base) do
		result[key] = value
	end
	for key, value in pairs(extra) do
		if type(key) == 'string' and type(value) == 'string' and not API_KEYS[key] then
			result[key] = value
		else
			left_out[#left_out + 1] = tostring(key)
		end
	end
	table.sort(left_out)
	return result, left_out
end

-- `get_keys(save_to_load)` returns a table of text keys to text values. One per mod; a second call
-- replaces it. save_to_load is the decoded Run save a crash rejoin is about to load, or nil on any
-- other join (a new lobby, a socket-drop rejoin, a rejoin with no good save): the mod decides then.
function MPAPI.add_join_keys(mod_id, get_keys)
	key_functions[mod_id] = get_keys
end

-- `base` with the keys the mod adds, or `base` itself when it adds none.
local function with_mod_keys(mod_id, base, save_to_load)
	local get_keys = key_functions[mod_id]
	if not get_keys then
		return base
	end
	local ok, extra = pcall(get_keys, save_to_load)
	if not ok or type(extra) ~= 'table' then
		MPAPI.sendWarnMessage('[join_keys] ' .. tostring(mod_id) .. ' gave no usable keys: ' .. tostring(extra))
		return base
	end
	local result, left_out = merged(base, extra)
	if #left_out > 0 then
		MPAPI.sendWarnMessage('[join_keys] ' .. tostring(mod_id) .. ' keys left out: ' .. table.concat(left_out, ', '))
	end
	return result
end

-- Whether the mod registered join keys.
local function has_keys(mod_id)
	return key_functions[mod_id] ~= nil
end

MPAPI.join_keys = {
	with_mod_keys = with_mod_keys,
	has_keys = has_keys,
}

return MPAPI.join_keys
