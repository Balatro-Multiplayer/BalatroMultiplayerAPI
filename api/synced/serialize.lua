-- Generic card (de)serialization for synced GameObjects — e.g. a magnet-style steal that
-- ships a full joker to the opponent. Ported from BalatroMultiplayerPvP/lib/serialization.lua.
-- STR_PACK / STR_UNPACK are base-game globals; the checked unpack sandboxes the payload
-- against code injection, and decode() caps the size against zip-bomb inputs.

-- From https://github.com/lunarmodules/Penlight (MIT license)
local function save_global_env()
	local env = {}
	env.hook, env.mask, env.count = debug.gethook()
	if env.hook ~= 'external hook' then debug.sethook() end
	env.string_mt = getmetatable('')
	debug.setmetatable('', nil)
	return env
end

local function restore_global_env(env)
	if env then
		debug.setmetatable('', env.string_mt)
		if env.hook ~= 'external hook' then debug.sethook(env.hook, env.mask, env.count) end
	end
end

local function STR_UNPACK_CHECKED(str)
	-- STR_PACK output should only return a table and nothing else.
	if str:sub(1, 8) ~= 'return {' then error('Invalid string header, expected "return {..."') end
	-- Naive anti-injection: disallow function definitions.
	if str:find('[^"\'%w_]function[^"\'%w_]') then error('Function keyword detected') end
	-- Load with an empty environment: no functions or globals available.
	local chunk = assert(load(str, nil, 't', {}))
	local global_env = save_global_env()
	local success, str_unpacked = pcall(chunk)
	restore_global_env(global_env)
	if not success then error(str_unpacked) end
	return str_unpacked
end

-- For callers that unpack text they did not make themselves (a Run save given back by the server).
MPAPI.str_unpack_checked = STR_UNPACK_CHECKED

-- A legitimately serialized object is at most a few KB gzipped+base64. Reject anything far
-- larger BEFORE spending CPU decoding it.
MPAPI.MAX_ENCODED_BYTES = 32 * 1024

-- table -> safe encoded string
function MPAPI.encode(data)
	local str = STR_PACK(data)
	local str_compressed = love.data.compress('string', 'gzip', str)
	return love.data.encode('string', 'base64', str_compressed)
end

-- encoded string -> table, or (nil, err)
function MPAPI.decode(str)
	local success, decoded, decompressed, unpacked
	if type(str) ~= 'string' then return nil, 'expected string payload' end
	if #str > MPAPI.MAX_ENCODED_BYTES then
		return nil, string.format('payload too large (%d > %d bytes)', #str, MPAPI.MAX_ENCODED_BYTES)
	end
	success, decoded = pcall(love.data.decode, 'string', 'base64', str)
	if not success then return nil, decoded end
	success, decompressed = pcall(love.data.decompress, 'string', 'gzip', decoded)
	if not success then return nil, decompressed end
	success, unpacked = pcall(STR_UNPACK_CHECKED, decompressed)
	if not success then return nil, unpacked end
	return unpacked
end

-- Serialize a live Card to a safe string.
function MPAPI.serialize_card(card)
	return MPAPI.encode(card:save())
end

-- Shape validation for card saves. decode() only sandboxes the *code* in a payload; a hostile
-- peer can still send a genuine save with a wrong-typed field (e.g. ability.h_size = "abc"), which
-- Card:load() copies in untouched and Card:add_to_deck() then does arithmetic on, crashing the
-- receiver. rebuild_card therefore shape-checks every save before building a card from it.
local MAX_DEPTH = 6
local MAX_STRING = 256
local MAX_ENTRIES = 256

-- Top-level ability fields the base game does arithmetic on; numbers when present.
local NUMERIC_ABILITY_KEYS = {
	'mult', 'h_mult', 'h_x_mult', 'h_dollars', 'p_dollars', 't_mult', 't_chips', 'x_mult', 'h_size', 'd_size',
	'extra_value', 'perma_bonus', 'bonus', 'x_chips', 'perma_x_mult', 'perma_mult', 'perma_h_chips',
	'perma_h_mult', 'perma_h_x_mult', 'perma_p_dollars', 'perma_h_dollars', 'perma_repetitions',
}

local function finite_number(v)
	return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

-- Plain data only: primitives and tables of primitives, bounded in depth and size.
local function plain_data(v, depth, budget)
	local t = type(v)
	if t == 'number' then return finite_number(v) end
	if t == 'boolean' then return true end
	if t == 'string' then return #v <= MAX_STRING end
	if t ~= 'table' or depth > MAX_DEPTH then return false end
	for k, child in pairs(v) do
		budget.n = budget.n + 1
		if budget.n > MAX_ENTRIES then return false end
		local kt = type(k)
		if kt ~= 'string' and kt ~= 'number' then return false end
		if kt == 'string' and #k > MAX_STRING then return false end
		if not plain_data(child, depth + 1, budget) then return false end
	end
	return true
end

-- Every field the center's default config defines must exist in the ability with the same type.
local function matches_config(config, ability, depth)
	if depth > MAX_DEPTH then return false end
	for k, default in pairs(config) do
		local v = ability[k]
		if type(v) ~= type(default) then return false end
		if type(default) == 'table' and not matches_config(default, v, depth + 1) then return false end
	end
	return true
end

-- Returns true, or false plus the reason. `area` is where the card would be emplaced.
function MPAPI.validate_card_save(save, area)
	if type(save) ~= 'table' then return false, 'save is not a table' end
	local fields = save.save_fields
	if type(fields) ~= 'table' then return false, 'save_fields missing' end
	local center = type(fields.center) == 'string' and G.P_CENTERS[fields.center] or nil
	if not center then return false, 'unknown center' end
	if area == G.jokers and center.set ~= 'Joker' then return false, 'not a joker' end
	if area == G.consumeables and not center.consumeable then return false, 'not a consumable' end
	local ability = save.ability
	if type(ability) ~= 'table' then return false, 'ability missing' end
	if not plain_data(ability, 1, { n = 0 }) then return false, 'ability is not plain data' end
	for _, key in ipairs(NUMERIC_ABILITY_KEYS) do
		local v = ability[key]
		if v ~= nil and not finite_number(v) then return false, 'ability.' .. key .. ' is not a number' end
	end
	if type(center.config) == 'table' and not matches_config(center.config, ability, 1) then
		return false, "ability does not match the center's config"
	end
	return true
end

-- Rebuild a serialized card into an area (default G.jokers) and add it to the deck.
-- Returns the new Card, or nil on failure (including a payload that fails shape validation). Mirrors PvP's action_magnet_response, including
-- the base-game 1.0.1o VT.h workaround.
function MPAPI.rebuild_card(str, area)
	local save, err = MPAPI.decode(str)
	if not save then
		MPAPI.sendWarnMessage('rebuild_card: ' .. tostring(err))
		return nil
	end
	area = area or G.jokers
	local valid, reason = MPAPI.validate_card_save(save, area)
	if not valid then
		MPAPI.sendWarnMessage('rebuild_card rejected payload: ' .. tostring(reason))
		return nil
	end
	local card = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W, G.CARD_H, G.P_CENTERS.j_joker, G.P_CENTERS.c_base)
	local ok, e = pcall(card.load, card, save)
	if not ok then
		MPAPI.sendWarnMessage('rebuild_card load: ' .. tostring(e))
		return nil
	end
	card:hard_set_VT()
	card.added_to_deck = nil
	card:add_to_deck()
	area:emplace(card)
	return card
end
