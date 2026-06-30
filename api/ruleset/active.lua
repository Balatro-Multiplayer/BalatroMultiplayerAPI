-- Queries for which ruleset/gamemode the current lobby has selected.

-- The full ruleset key from the current lobby's metadata, or nil.
function MPAPI.get_active_ruleset()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if lobby then return lobby:get_metadata().ruleset end
	return nil
end

-- The full gamemode key from the current lobby's metadata, or nil.
function MPAPI.get_active_gamemode()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if lobby then return lobby:get_metadata().gamemode end
	return nil
end

function MPAPI.is_ruleset_active(ruleset_key)
	return MPAPI.get_active_ruleset() == ruleset_key
end
