-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the layer system this is based on.
-- Layer registration and the reverse indices that map a full content key to the
-- layers that rework it.
MPAPI.Layers = MPAPI.Layers or {}

-- full key -> array of layer names that list it, used to auto-attach mp_include
-- on cards whose only gating is layer membership (see api/layers/pool_gating.lua).
MPAPI._JOKER_LAYERS = MPAPI._JOKER_LAYERS or {}
MPAPI._CONSUMABLE_LAYERS = MPAPI._CONSUMABLE_LAYERS or {}
MPAPI._TAG_LAYERS = MPAPI._TAG_LAYERS or {}

local function index_keys(keys, index_table, layer_name)
	if not keys then return end
	for _, key in ipairs(keys) do
		index_table[key] = index_table[key] or {}
		table.insert(index_table[key], layer_name)
	end
end

function MPAPI.Layer(name, definition)
	MPAPI.Layers[name] = definition
	index_keys(definition.reworked_jokers, MPAPI._JOKER_LAYERS, name)
	index_keys(definition.reworked_consumables, MPAPI._CONSUMABLE_LAYERS, name)
	index_keys(definition.reworked_tags, MPAPI._TAG_LAYERS, name)
end
