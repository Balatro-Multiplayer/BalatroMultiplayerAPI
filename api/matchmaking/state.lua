MPAPI.matchmaking = MPAPI.matchmaking or {}

-- Shared matchmaking state and the helpers that operate on it. Kept in one place
-- so the handle, dispatch and public-API files reach it through MPAPI._internal.mm
-- rather than capturing file-local upvalues (which cannot cross files). Defensive
-- init keeps the four matchmaking files independent of load order.
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

mm.handles = mm.handles or {} -- active queue handles

-- The handle queued for a mod's mode. The server names a queue by the bare
-- board name (the ticket's mode, a 'ranked:' key prefix dropped), so a ranked
-- handle, whose game_mode keeps the prefix, is found by either spelling. An
-- exact match wins over a prefixed one.
function mm.find_handle_by_mode(mod_id, game_mode)
	local prefixed
	for _, h in ipairs(mm.handles) do
		if h.mod_id == mod_id then
			if h.game_mode == game_mode then
				return h
			end
			if h.game_mode == 'ranked:' .. tostring(game_mode) then
				prefixed = prefixed or h
			end
		end
	end
	return prefixed
end

function mm.remove_handle(handle)
	for i, h in ipairs(mm.handles) do
		if h == handle then
			table.remove(mm.handles, i)
			break
		end
	end
end
