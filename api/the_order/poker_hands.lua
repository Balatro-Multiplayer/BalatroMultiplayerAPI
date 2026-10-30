-- Visible poker hands in hand order, without current_hand. A pick from this list does not
-- depend on pairs() order, so both players get the same hand.
function MPAPI.sorted_hand_list(current_hand)
	if not current_hand then current_hand = 'NULL' end
	local _poker_hands = {}
	local done = false
	local order = 1
	while not done do
		done = true
		for k, v in pairs(G.GAME.hands) do
			if v.order == order then
				order = order + 1
				done = false
				if v.visible and k ~= current_hand then _poker_hands[#_poker_hands + 1] = k end
			end
		end
	end
	return _poker_hands
end
