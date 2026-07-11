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

-- Rebuild a serialized card into an area (default G.jokers) and add it to the deck.
-- Returns the new Card, or nil on failure. Mirrors PvP's action_magnet_response, including
-- the base-game 1.0.1o VT.h workaround.
function MPAPI.rebuild_card(str, area)
	local save, err = MPAPI.decode(str)
	if not save then
		MPAPI.sendWarnMessage('rebuild_card: ' .. tostring(err))
		return nil
	end
	area = area or G.jokers
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
