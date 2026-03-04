function MPAPI.config_get(key)
	return MPAPI.config[key]
end

function MPAPI.config_set(key, value)
	MPAPI.config[key] = value
	SMODS.save_mod_config(MPAPI)
end

function MPAPI.config_on_connect(connection)
	local discord_linked = connection.discord_name and connection.discord_name ~= ''
	if not discord_linked and MPAPI.config.use_discord_name then
		MPAPI.config_set('use_discord_name', false)
	end
end
