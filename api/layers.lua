-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the layer system this is based on.

MPAPI.Layers = {}

-- Reverse indices: full key -> array of layer names that list it.
-- Used to auto-attach mp_include on cards whose only gating is layer membership.
MPAPI._JOKER_LAYERS = {}
MPAPI._CONSUMABLE_LAYERS = {}
MPAPI._TAG_LAYERS = {}

function MPAPI.Layer(name, definition)
	MPAPI.Layers[name] = definition
	if definition.reworked_jokers then
		for _, joker_key in ipairs(definition.reworked_jokers) do
			MPAPI._JOKER_LAYERS[joker_key] = MPAPI._JOKER_LAYERS[joker_key] or {}
			table.insert(MPAPI._JOKER_LAYERS[joker_key], name)
		end
	end
	if definition.reworked_consumables then
		for _, consumable_key in ipairs(definition.reworked_consumables) do
			MPAPI._CONSUMABLE_LAYERS[consumable_key] = MPAPI._CONSUMABLE_LAYERS[consumable_key] or {}
			table.insert(MPAPI._CONSUMABLE_LAYERS[consumable_key], name)
		end
	end
	if definition.reworked_tags then
		for _, tag_key in ipairs(definition.reworked_tags) do
			MPAPI._TAG_LAYERS[tag_key] = MPAPI._TAG_LAYERS[tag_key] or {}
			table.insert(MPAPI._TAG_LAYERS[tag_key], name)
		end
	end
end

-- Build an mp_include closure that returns true iff any of the named layers is active.
local function layer_membership_include(owning_layers)
	return function(_)
		return MPAPI.is_any_layer_active(owning_layers)
	end
end

function MPAPI.should_exclude_from_pool(v)
	if v.mp_include and type(v.mp_include) == 'function' then return not v:mp_include() end
	if v.key and v.key:match('^%a+_mp_') then return true end
	return false
end

local function warn_if_ungated(key, kind, prefix)
	if key and key:sub(1, #prefix) == prefix then
		MPAPI.sendDebugMessage(
			'WARNING: '
				.. kind
				.. ' '
				.. key
				.. ' has no mp_include and is not in any reworked list. '
				.. 'Under default-deny it will be excluded from every ruleset pool. '
				.. 'Either add the key to a layer/ruleset reworked_'
				.. kind
				.. 's, or define an explicit mp_include.'
		)
	end
end

local _original_joker_register = SMODS.Joker.register
function SMODS.Joker:register()
	if not self.mp_include and MPAPI._JOKER_LAYERS[self.key] then
		local owning_layers = MPAPI._JOKER_LAYERS[self.key]
		MPAPI.sendDebugMessage('Auto-gating ' .. self.key .. ' on layers: ' .. table.concat(owning_layers, ', '))
		self.mp_include = layer_membership_include(owning_layers)
	end
	if not self.mp_include then warn_if_ungated(self.key, 'joker', 'j_mpapi_') end
	return _original_joker_register(self)
end

local _original_consumable_register = SMODS.Consumable.register
function SMODS.Consumable:register()
	if not self.mp_include and MPAPI._CONSUMABLE_LAYERS[self.key] then
		local owning_layers = MPAPI._CONSUMABLE_LAYERS[self.key]
		MPAPI.sendDebugMessage('Auto-gating ' .. self.key .. ' on layers: ' .. table.concat(owning_layers, ', '))
		self.mp_include = layer_membership_include(owning_layers)
	end
	if not self.mp_include then warn_if_ungated(self.key, 'consumable', 'c_mpapi_') end
	return _original_consumable_register(self)
end

local _original_tag_register = SMODS.Tag.register
function SMODS.Tag:register()
	if not self.mp_include and MPAPI._TAG_LAYERS[self.key] then
		local owning_layers = MPAPI._TAG_LAYERS[self.key]
		MPAPI.sendDebugMessage('Auto-gating ' .. self.key .. ' on layers: ' .. table.concat(owning_layers, ', '))
		self.mp_include = layer_membership_include(owning_layers)
	end
	if not self.mp_include then warn_if_ungated(self.key, 'tag', 'tag_mpapi_') end
	return _original_tag_register(self)
end

-- Array-valued fields that get merged (layer base + ruleset additions).
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

-- Resolve layers on the init table before construction validates required params.
-- Scalars: last layer wins, but the ruleset's own value always beats any layer.
-- Arrays: concatenated across all layers + ruleset.
function MPAPI.resolve_layers(init)
	if not init.layers then
		for _, field in ipairs(MPAPI._LAYER_ARRAY_FIELDS) do
			if init[field] == nil then init[field] = {} end
		end
		return init
	end
	local ruleset_owned = {}
	for k in pairs(init) do
		ruleset_owned[k] = true
	end
	for _, layer_name in ipairs(init.layers) do
		local layer = MPAPI.Layers[layer_name]
		if not layer then error('MPAPI.resolve_layers: unknown layer: ' .. tostring(layer_name)) end
		for k, v in pairs(layer) do
			if type(v) == 'table' then
				if init[k] == nil then
					local copy = {}
					for i, item in ipairs(v) do copy[i] = item end
					init[k] = copy
				elseif type(init[k]) == 'table' then
					local merged = {}
					for _, item in ipairs(v) do merged[#merged + 1] = item end
					for _, item in ipairs(init[k]) do merged[#merged + 1] = item end
					init[k] = merged
				end
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
	for _, field in ipairs(MPAPI._LAYER_ARRAY_FIELDS) do
		if init[field] == nil then init[field] = {} end
	end
	return init
end

-- ----------------------------------------------------------------------------
-- Modifier layers
-- ----------------------------------------------------------------------------
-- MPAPI.MODIFIERS is an ordered list of layer names active at runtime (chosen
-- per lobby / run). Reset to {} on lobby leave. Modifiers stack on top of the
-- active ruleset without being baked into it.

MPAPI.MODIFIERS = {}

function MPAPI.has_modifier(name)
	for _, n in ipairs(MPAPI.MODIFIERS) do
		if n == name then return true end
	end
	return false
end

function MPAPI.add_modifier(name)
	if not name or name == '' or MPAPI.has_modifier(name) then return end
	MPAPI.MODIFIERS[#MPAPI.MODIFIERS + 1] = name
end

function MPAPI.remove_modifier(name)
	for i, n in ipairs(MPAPI.MODIFIERS) do
		if n == name then
			table.remove(MPAPI.MODIFIERS, i)
			return
		end
	end
end

function MPAPI.modifiers_serialize()
	return table.concat(MPAPI.MODIFIERS, ',')
end

function MPAPI.modifiers_parse(s)
	MPAPI.MODIFIERS = {}
	if not s or s == '' then return end
	for n in string.gmatch(s, '[^,]+') do
		MPAPI.MODIFIERS[#MPAPI.MODIFIERS + 1] = n
	end
end

function MPAPI.apply_default_modifiers(ruleset_key)
	MPAPI.MODIFIERS = {}
	if not ruleset_key then return end
	local ruleset = MPAPI.Rulesets[ruleset_key]
	if not ruleset or not ruleset.default_modifiers then return end
	for _, name in ipairs(ruleset.default_modifiers) do
		MPAPI.add_modifier(name)
	end
end

-- Returns a single deduped ordered list of active layer names:
-- the target ruleset's _layer_order, then its own key, then modifiers
-- (only when target is the currently active ruleset).
function MPAPI.active_layer_chain(target_key)
	local active_key = MPAPI.get_active_ruleset and MPAPI.get_active_ruleset() or nil
	target_key = target_key or active_key

	local result, seen = {}, {}
	local function add(name)
		if name and not seen[name] then
			seen[name] = true
			result[#result + 1] = name
		end
	end

	if target_key then
		local ruleset = MPAPI.Rulesets and MPAPI.Rulesets[target_key] or nil
		if ruleset and ruleset._layer_order then
			for _, name in ipairs(ruleset._layer_order) do add(name) end
		end
		add(target_key)
	end
	if target_key == active_key then
		for _, name in ipairs(MPAPI.MODIFIERS) do add(name) end
	end
	return result
end

-- Fire a named hook on every layer in the active chain.
function MPAPI.RunLayerHooks(hook_name)
	for _, name in ipairs(MPAPI.active_layer_chain()) do
		local layer = MPAPI.Layers[name]
		if layer and layer[hook_name] then layer[hook_name]() end
	end
end

function MPAPI.is_layer_active(layer_name)
	if not layer_name then return false end
	for _, name in ipairs(MPAPI.active_layer_chain()) do
		if name == layer_name then return true end
	end
	return false
end

function MPAPI.is_any_layer_active(layers)
	for _, layer_name in pairs(layers) do
		if MPAPI.is_layer_active(layer_name) then return true end
	end
	return false
end
