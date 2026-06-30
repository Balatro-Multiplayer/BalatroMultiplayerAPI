-- Runtime modifier layers: an ordered list of layer names active for the current
-- lobby/run that stack on top of the active ruleset without being baked into it.
-- Reset to {} on lobby leave.
MPAPI.MODIFIERS = MPAPI.MODIFIERS or {}

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
