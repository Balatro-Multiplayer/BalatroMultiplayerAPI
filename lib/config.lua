-- Gets a value from the MPAPI config by its key
function MPAPI._internal.config_get(key)
	return MPAPI.config[key]
end

-- Sets a value from the MPAPI config by its key
function MPAPI._internal.config_set(key, value)
	MPAPI.config[key] = value
	SMODS.save_mod_config(MPAPI)
end
