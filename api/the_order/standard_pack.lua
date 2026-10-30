-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
-- Take ownership of standard pack card creation to use queue-based seeding.
SMODS.Booster:take_ownership_by_kind('Standard', {
	create_card = function(self, card, i)
		local s_append = ''
		local b_append = MPAPI.ante_based() .. s_append
		local _edition = poll_edition('standard_edition' .. b_append, 2, true)
		local _seal = SMODS.poll_seal({ mod = 10 })
		return {
			set = (pseudorandom(pseudoseed('stdset' .. b_append)) > 0.6) and 'Enhanced' or 'Base',
			edition = _edition,
			seal = _seal,
			area = G.pack_cards,
			skip_materialize = true,
			soulable = true,
			key_append = 'sta' .. s_append,
			front = false,
		}
	end,
}, true)
