-- Pure composition of a ruleset init table with its declared layers, plus the
-- field schemas that govern how each kind of field merges. No effects.

-- Array-valued fields, concatenated across all layers + the ruleset.
MPAPI._LAYER_ARRAY_FIELDS = {
	'banned_jokers',
	'banned_consumables',
	'banned_vouchers',
	'banned_enhancements',
	'banned_tags',
	'banned_blinds',
	'banned_silent',
	'reworked_jokers',
	'reworked_consumables',
	'reworked_vouchers',
	'reworked_enhancements',
	'reworked_tags',
	'reworked_blinds',
	'spectral_banned_enhancements',
	'stickers',
}

-- Dict-table fields, key-level merged: later source wins per key; ruleset wins over layers.
MPAPI._LAYER_TABLE_FIELDS = {
	'game_modifiers',
	'starting_params',
}

local function table_field_set()
	local set = {}
	for _, f in ipairs(MPAPI._LAYER_TABLE_FIELDS) do set[f] = true end
	return set
end

local function default_empty_arrays(init)
	for _, field in ipairs(MPAPI._LAYER_ARRAY_FIELDS) do
		if init[field] == nil then init[field] = {} end
	end
end

local function merge_dict_field(init, key, value, ruleset_owns_key)
	if init[key] == nil then init[key] = {} end
	if ruleset_owns_key then
		for fk, fv in pairs(value) do
			if init[key][fk] == nil then init[key][fk] = fv end
		end
	else
		for fk, fv in pairs(value) do init[key][fk] = fv end
	end
end

local function merge_array_field(init, key, value)
	if init[key] == nil then
		local copy = {}
		for i, item in ipairs(value) do copy[i] = item end
		init[key] = copy
	elseif type(init[key]) == 'table' then
		local merged = {}
		for _, item in ipairs(value) do merged[#merged + 1] = item end
		for _, item in ipairs(init[key]) do merged[#merged + 1] = item end
		init[key] = merged
	end
end

-- Scalars: last layer wins, but the ruleset's own value always beats any layer.
-- Arrays: concatenated across all layers + ruleset.
-- Dict-tables: key-level merge; later layers overwrite earlier; ruleset wins over layers.
function MPAPI.resolve_layers(init)
	if not init.layers then
		default_empty_arrays(init)
		return init
	end

	local is_table_field = table_field_set()
	local ruleset_owned = {}
	for k in pairs(init) do
		ruleset_owned[k] = true
	end

	for _, layer_name in ipairs(init.layers) do
		local layer = MPAPI.Layers[layer_name]
		if not layer then error('MPAPI.resolve_layers: unknown layer: ' .. tostring(layer_name)) end
		for k, v in pairs(layer) do
			if type(v) == 'table' and is_table_field[k] then
				merge_dict_field(init, k, v, ruleset_owned[k])
			elseif type(v) == 'table' then
				merge_array_field(init, k, v)
			elseif not ruleset_owned[k] then
				init[k] = v
			end
		end
	end

	local layer_set = {}
	local layer_order = {}
	for _, layer_name in ipairs(init.layers) do
		layer_set[layer_name] = true
		layer_order[#layer_order + 1] = layer_name
	end
	init._layers = layer_set
	init._layer_order = layer_order
	init.layers = nil

	default_empty_arrays(init)
	return init
end
