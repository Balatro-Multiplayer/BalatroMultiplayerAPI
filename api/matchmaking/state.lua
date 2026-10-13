MPAPI.matchmaking = MPAPI.matchmaking or {}

-- Shared matchmaking state and the helpers that operate on it. Kept in one place
-- so the handle, dispatch and public-API files reach it through MPAPI._internal.mm
-- rather than capturing file-local upvalues (which cannot cross files). Defensive
-- init keeps the four matchmaking files independent of load order.
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

mm.handles = mm.handles or {} -- active queue handles

function mm.find_handle_by_mode(mod_id, game_mode)
	for _, h in ipairs(mm.handles) do
		if h.mod_id == mod_id and h.game_mode == game_mode then
			return h
		end
	end
	return nil
end

function mm.remove_handle(handle)
	for i, h in ipairs(mm.handles) do
		if h == handle then
			table.remove(mm.handles, i)
			break
		end
	end
end
