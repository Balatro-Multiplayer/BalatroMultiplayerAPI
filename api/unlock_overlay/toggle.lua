-- Focus-driven on/off switch, called from api/mod_registry/focus.lua at every place
-- state.focused_mod changes. See that file's comments for why those four call sites are the
-- complete signal -- page-category transitions and G.FUNCS.start_run were both considered and
-- rejected as hook points (the former is redundant, the latter is also used by MPAPI mods
-- themselves to start their own matches, so it can't distinguish "real singleplayer" from "an
-- MPAPI match").
MPAPI._internal.unlock_overlay = MPAPI._internal.unlock_overlay or {}
local ov = MPAPI._internal.unlock_overlay

-- Called right after state.focused_mod is set to a real mod id. Reverts any previous overlay
-- first (idempotent no-op if nothing was active) so switching directly between two mods with no
-- vanilla screen in between still ends with only the new mod's overlay state active.
MPAPI._internal.unlock_overlay.enable_for_mod = function(id)
	ov.revert()
	local mod = MPAPI._internal.mod_registry.registered_mods[id]
	if mod and mod.unlock_overlay ~= false then
		ov.apply()
		ov.active_mod = id
	else
		ov.active_mod = nil
	end
end

-- Called right after state.focused_mod is cleared back to nil (leaving to vanilla, or a mid-run
-- lobby disconnect falling back to vanilla).
MPAPI._internal.unlock_overlay.disable = function()
	ov.revert()
	ov.active_mod = nil
end
