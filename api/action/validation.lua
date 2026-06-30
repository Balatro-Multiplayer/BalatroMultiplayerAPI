-- Pure: validates params against an ActionType parameter schema. Returns an error
-- message string describing the first violation, or nil when valid. No I/O.
MPAPI._internal.validate_action_params = function(schema, params)
	if not schema then
		return nil
	end
	params = params or {}
	for _, entry in ipairs(schema) do
		if entry.required and params[entry.key] == nil then
			return 'missing required param: ' .. tostring(entry.key)
		end
		if entry.type and params[entry.key] ~= nil and type(params[entry.key]) ~= entry.type then
			return 'param "' .. tostring(entry.key) .. '" expected ' .. entry.type .. ', got ' .. type(params[entry.key])
		end
	end
	return nil
end
