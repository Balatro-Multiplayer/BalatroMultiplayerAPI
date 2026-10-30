-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
-- Patches card creation to not be ante-based and use a single pool for every type/rarity.
local _cc = create_card
function create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
	if MPAPI.should_use_the_order() then
		local a = G.GAME.round_resets.ante
		G.GAME.round_resets.ante = 0
		G.GAME.round_resets.mp_real_ante = a
		if _type == 'Tarot' or _type == 'Planet' or _type == 'Spectral' then
			if area == G.pack_cards then
				key_append = _type .. '_pack'
			else
				key_append = _type
			end
		elseif not (_type == 'Base' or _type == 'Enhanced') then
			if key_append == 'jud' and G.GAME.modifiers.enable_eternals_in_shop then
				_rarity = pseudorandom('order_jud_rarity')
			end
			key_append = nil
		end
		local c = _cc(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
		G.GAME.round_resets.ante = a
		G.GAME.round_resets.mp_real_ante = nil
		return c
	end
	return _cc(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
end
