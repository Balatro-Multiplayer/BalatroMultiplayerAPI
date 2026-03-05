-- Gets a value from the MPAPI config by its key
MPAPI._internal.config_get = function(key)
	return MPAPI.config[key]
end

-- Sets a value from the MPAPI config by its key
MPAPI._internal.config_set = function(key, value)
	MPAPI.config[key] = value
	SMODS.save_mod_config(MPAPI)
end
