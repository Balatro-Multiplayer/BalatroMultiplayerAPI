-- A GameMode/Ruleset/Layer's calculate (or a GameMode's on_player_forfeit) can
-- return { winner = player_id } instead of broadcasting a win itself -- the
-- actual mechanism (which ActionType, how to build the payload) is registered
-- once per mod, so individual gamemodes never touch an ActionType or a lobby
-- object at all.

MPAPI._winner_handlers = MPAPI._winner_handlers or {}

function MPAPI.on_winner_declared(handler)
	MPAPI._winner_handlers[SMODS.current_mod.id] = handler
end

-- Only meaningful once per match; if two participants both declare a winner in
-- the same dispatch, each mod's own handler fires independently (no merge
-- collision, just two broadcasts) -- a latent edge case with no current real
-- trigger, not worth guarding further.
function MPAPI._handle_gamemode_result(instance, result)
	if type(result) == 'table' and result.winner then
		local mod_id = instance and instance.mod and instance.mod.id
		local handler = mod_id and MPAPI._winner_handlers[mod_id]
		if handler then handler(result.winner) end
	end
	return result
end
