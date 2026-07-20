-- Pure read model answering "what's in the active ruleset?": the baked ruleset
-- value with runtime modifier layers overlaid per field kind. Safe with no active
-- ruleset (arrays read as {}, the rest as nil).

local function field_kind_sets()
	local arrays, tables = {}, {}
	for _, f in ipairs(MPAPI._LAYER_ARRAY_FIELDS) do arrays[f] = true end
	for _, f in ipairs(MPAPI._LAYER_TABLE_FIELDS) do tables[f] = true end
	return arrays, tables
end

local function resolve_array_field(ruleset, field)
	local merged = {}
	if ruleset and ruleset[field] then
		for _, v in ipairs(ruleset[field]) do merged[#merged + 1] = v end
	end
	for _, mod_name in ipairs(MPAPI.MODIFIERS) do
		local layer = MPAPI.Layers[mod_name]
		if layer and layer[field] then
			for _, v in ipairs(layer[field]) do merged[#merged + 1] = v end
		end
	end
	return merged
end

-- Start from the baked ruleset value (already includes static layer
-- contributions), then overlay runtime modifier layers (modifier > baked).
local function resolve_table_field(ruleset, field)
	local merged = {}
	if ruleset and ruleset[field] then
		for fk, fv in pairs(ruleset[field]) do merged[fk] = fv end
	end
	for _, mod_name in ipairs(MPAPI.MODIFIERS) do
		local layer = MPAPI.Layers[mod_name]
		if layer and layer[field] then
			for fk, fv in pairs(layer[field]) do merged[fk] = fv end
		end
	end
	return merged
end

-- Scalars: latest modifier with a value wins, else the baked ruleset value.
local function resolve_scalar_field(ruleset, field)
	for i = #MPAPI.MODIFIERS, 1, -1 do
		local layer = MPAPI.Layers[MPAPI.MODIFIERS[i]]
		if layer and layer[field] ~= nil then return layer[field] end
	end
	if ruleset then return ruleset[field] end
	return nil
end

-- Resolves a single field for an explicit ruleset key -- not necessarily the
-- active one. The entry point for consumers with their own active-ruleset
-- resolution (e.g. PvP's lobby/practice-mode/ghost-replay logic, which
-- MPAPI.get_active_ruleset()'s lobby-only check can't see) should call this
-- directly instead of reimplementing the field-kind merge logic.
function MPAPI.resolve_ruleset_field(ruleset_key, field)
	local ruleset = ruleset_key and MPAPI.Rulesets[ruleset_key] or nil
	local is_array, is_table = field_kind_sets()
	if is_array[field] then return resolve_array_field(ruleset, field) end
	if is_table[field] then return resolve_table_field(ruleset, field) end
	return resolve_scalar_field(ruleset, field)
end

local _resolver = setmetatable({}, {
	__index = function(_, field) return MPAPI.resolve_ruleset_field(MPAPI.get_active_ruleset(), field) end,
})

function MPAPI.current_ruleset()
	return _resolver
end
