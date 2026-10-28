-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
-- Patch seal polling to use a single game-long queue when The Order is active.
local _pollseal = SMODS.poll_seal
function SMODS.poll_seal(args)
	if MPAPI.should_use_the_order() then
		local a = G.GAME.round_resets.ante
		G.GAME.round_resets.ante = 0
		G.GAME.round_resets.mp_real_ante = a
		local ret = _pollseal(args)
		G.GAME.round_resets.ante = a
		G.GAME.round_resets.mp_real_ante = nil
		return ret
	end
	return _pollseal(args)
end
