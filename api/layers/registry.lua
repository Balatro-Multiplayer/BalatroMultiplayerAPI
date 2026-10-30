-- Layer registration and the reverse indices that map a full content key to the
-- layers that list it. See docs/layers.md.
MPAPI.Layers = MPAPI.Layers or {}

-- full key -> array of layer names that list it, used to auto-attach mp_include
-- on cards whose only gating is layer membership (see api/layers/pool_gating.lua).
MPAPI._JOKER_LAYERS = MPAPI._JOKER_LAYERS or {}
MPAPI._CONSUMABLE_LAYERS = MPAPI._CONSUMABLE_LAYERS or {}
MPAPI._TAG_LAYERS = MPAPI._TAG_LAYERS or {}
MPAPI._VOUCHER_LAYERS = MPAPI._VOUCHER_LAYERS or {}
MPAPI._ENHANCEMENT_LAYERS = MPAPI._ENHANCEMENT_LAYERS or {}
MPAPI._BLIND_LAYERS = MPAPI._BLIND_LAYERS or {}

local function index_keys(keys, index_table, layer_name)
	if not keys then return end
	for _, key in ipairs(keys) do
		index_table[key] = index_table[key] or {}
		table.insert(index_table[key], layer_name)
	end
end

function MPAPI.Layer(name, definition)
	assert(not MPAPI.Layers[name], 'MPAPI.Layer: duplicate layer name: ' .. tostring(name))
	MPAPI.Layers[name] = definition
	-- included_* and reworked_* do the same thing: a listed card only spawns
	-- while this layer is active. reworked_* is the old name, from when every
	-- listed card was a replacement for a banned vanilla one.
	index_keys(definition.included_jokers, MPAPI._JOKER_LAYERS, name)
	index_keys(definition.included_consumables, MPAPI._CONSUMABLE_LAYERS, name)
	index_keys(definition.included_tags, MPAPI._TAG_LAYERS, name)
	index_keys(definition.included_vouchers, MPAPI._VOUCHER_LAYERS, name)
	index_keys(definition.included_enhancements, MPAPI._ENHANCEMENT_LAYERS, name)
	index_keys(definition.included_blinds, MPAPI._BLIND_LAYERS, name)
	index_keys(definition.reworked_jokers, MPAPI._JOKER_LAYERS, name)
	index_keys(definition.reworked_consumables, MPAPI._CONSUMABLE_LAYERS, name)
	index_keys(definition.reworked_tags, MPAPI._TAG_LAYERS, name)
	index_keys(definition.reworked_vouchers, MPAPI._VOUCHER_LAYERS, name)
	index_keys(definition.reworked_enhancements, MPAPI._ENHANCEMENT_LAYERS, name)
	index_keys(definition.reworked_blinds, MPAPI._BLIND_LAYERS, name)
end
