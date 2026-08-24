-- A GameMode/Ruleset/Layer's calculate (or a GameMode's on_player_forfeit) can
-- return { winner = player_id } (or { draw = true }, for an outcome with no
-- single winner -- e.g. simultaneous elimination, or a unanimous draw vote)
-- instead of broadcasting a result itself -- the actual mechanism (which
-- ActionType, how to build the payload) is registered once per mod, so
-- individual gamemodes never touch an ActionType or a lobby object at all.

MPAPI._winner_handlers = MPAPI._winner_handlers or {}
MPAPI._draw_handlers = MPAPI._draw_handlers or {}

function MPAPI.on_winner_declared(handler)
	MPAPI._winner_handlers[SMODS.current_mod.id] = handler
end

-- Registers this mod's handler for a drawn match (no winner). Takes no
-- arguments -- unlike a winner, a draw has no payload to carry.
function MPAPI.on_draw_declared(handler)
	MPAPI._draw_handlers[SMODS.current_mod.id] = handler
end

-- Only meaningful once per match; if two participants both declare a result in
-- the same dispatch, each mod's own handler fires independently (no merge
-- collision, just two broadcasts) -- a latent edge case with no current real
-- trigger, not worth guarding further.
function MPAPI._handle_gamemode_result(instance, result)
	if type(result) == 'table' then
		local mod_id = instance and instance.mod and instance.mod.id
		if result.winner then
			local handler = mod_id and MPAPI._winner_handlers[mod_id]
			if handler then handler(result.winner) end
		elseif result.draw then
			local handler = mod_id and MPAPI._draw_handlers[mod_id]
			if handler then handler() end
		end
	end
	return result
end
