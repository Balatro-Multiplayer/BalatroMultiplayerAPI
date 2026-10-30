-- Uncommon Tag and Rare Tag as The Order reworks them.
MPAPI.ReworkCenter('tag_uncommon', {
	layers = 'the_order',
	center_table = 'P_TAGS',
	apply = function(self, tag, context)
		if context.type == 'store_joker_create' then
			local card = create_card('Joker', context.area, nil, 0.9, nil, nil, nil, 'uta')
			create_shop_card_ui(card, 'Joker', context.area)
			card.states.visible = false
			tag:yep('+', G.C.GREEN, function()
				card:start_materialize()
				return true
			end)
			tag.triggered = true
			return card
		end
	end,
})

MPAPI.ReworkCenter('tag_rare', {
	layers = 'the_order',
	center_table = 'P_TAGS',
	apply = function(self, tag, context)
		if context.type == 'store_joker_create' then
			local card = nil
			local rares_in_posession = { 0 }
			for _, v in ipairs(G.jokers.cards) do
				if v.config.center.rarity == 3 and not rares_in_posession[v.config.center.key] then
					rares_in_posession[1] = rares_in_posession[1] + 1
					rares_in_posession[v.config.center.key] = true
				end
			end
			if #G.P_JOKER_RARITY_POOLS[3] > rares_in_posession[1] then
				card = create_card('Joker', context.area, nil, 1, nil, nil, nil, 'rta')
				create_shop_card_ui(card, 'Joker', context.area)
				card.states.visible = false
				tag:yep('+', G.C.RED, function()
					card:start_materialize()
					return true
				end)
			else
				tag:nope()
			end
			tag.triggered = true
			return card
		end
	end,
})
