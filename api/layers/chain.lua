-- Queries over the active layer chain: the deduped ordered list of layers in
-- effect, plus membership tests built on top of it.

-- Returns the deduped ordered list of active layer names: the target ruleset's
-- _layer_order, then its own key, then modifiers (only when the target is the
-- currently active ruleset).
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
