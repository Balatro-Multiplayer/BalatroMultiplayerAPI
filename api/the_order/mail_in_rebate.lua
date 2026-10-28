-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
-- Patches mail rank RNG to weight selection by rank frequency in deck.
local _original_reset_mail_rank = reset_mail_rank
function reset_mail_rank()
	if MPAPI.should_use_the_order() then
		G.GAME.current_round.mail_card.rank = 'Ace'

		local count_map = {}
		local valid_ranks = {}
		local value_order = {}
		for i, rank in ipairs(SMODS.Rank.obj_buffer) do value_order[rank] = i end

		-- valid_ranks shares its entries with count_map, so the tallies below land on the
		-- entries the sort and the weighted pick read (copies would stay at count = 0 and
		-- the sort would never order by count).
		for _, v in ipairs(G.playing_cards) do
			if v.ability.effect ~= 'Stone Card' then
				local val = v.base.value
				if not count_map[val] then
					count_map[val] = { value = val, count = 0, example_card = v }
					table.insert(valid_ranks, count_map[val])
				end
				count_map[val].count = count_map[val].count + 1
			end
		end
		if #valid_ranks == 0 then return end

		table.sort(valid_ranks, function(a, b)
			if a.count ~= b.count then return a.count > b.count end
			return value_order[a.value] < value_order[b.value]
		end)

		local total_weight = 0
		for _, entry in ipairs(valid_ranks) do total_weight = total_weight + entry.count end

		local raw_random = pseudorandom('mail' .. G.GAME.round_resets.ante)
		local threshold = 0
		for _, entry in ipairs(valid_ranks) do
			threshold = threshold + (entry.count / total_weight)
			if raw_random < threshold then
				G.GAME.current_round.mail_card.rank = entry.example_card.base.value
				G.GAME.current_round.mail_card.id = entry.example_card.base.id
				break
			end
		end
		return
	end
	return _original_reset_mail_rank()
end
