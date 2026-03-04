function MPAPI.config_get(key)
	return MPAPI.config[key]
end

function MPAPI.config_set(key, value)
	MPAPI.config[key] = value
	SMODS.save_mod_config(MPAPI)
end
