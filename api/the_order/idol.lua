-- The Idol's card under The Order: a weighted pick, by copies in the deck, over the candidates
-- in the order idol_scoring.lua scores them. The Idol also follows this under consumers'
-- idol gates (PvP's major-league ruleset), which play without The Order.
local _original_reset_idol_card = reset_idol_card
function reset_idol_card()
	if MPAPI.should_use_the_order() or MPAPI._internal.the_order.idol_follows_the_order() then
		G.GAME.current_round.idol_card.rank = 'Ace'
		G.GAME.current_round.idol_card.suit = 'Spades'

		local valid_idol_cards = MPAPI._internal.the_order.rank_idol_candidates(
			G.playing_cards,
			{ order = SMODS.Rank.obj_buffer, by_key = SMODS.Ranks },
			SMODS.Suit.obj_buffer,
			{
				sock_and_buskin = next(SMODS.find_card('j_sock_and_buskin')) ~= nil,
				hack = next(SMODS.find_card('j_hack')) ~= nil,
			}
		)
		if #valid_idol_cards == 0 then return end

		local total_weight = 0
		for _, entry in ipairs(valid_idol_cards) do total_weight = total_weight + entry.count end
		if total_weight <= 0 then return end

		local raw_random = pseudorandom('idol' .. G.GAME.round_resets.ante)
		local threshold = 0
		for _, entry in ipairs(valid_idol_cards) do
			threshold = threshold + (entry.count / total_weight)
			if raw_random < threshold then
				local idol_card = entry.card
			sendDebugMessage(
					string.format(
						'(Idol) Selected %s of %s, with a count of %d',
						idol_card.base.value, idol_card.base.suit, entry.count
					),
					'IdolAlgo'
				)
				G.GAME.current_round.idol_card.rank = idol_card.base.value
				G.GAME.current_round.idol_card.suit = idol_card.base.suit
				G.GAME.current_round.idol_card.id = idol_card.base.id

				-- Log the hit so the website log parser can show which card won and how
				-- likely it was. Cards are compact "<rank><suit><count>" tokens in
				-- selection order (T = 10), base64'd so the line stays one token:
				--   IDOL_ROLL::<base64 of {"roll":0.62,"winner":"QH","cards":["KS4","QH3","AS1"]}>
				local rank_codes = { Ace = 'A', King = 'K', Queen = 'Q', Jack = 'J', ['10'] = 'T' }
				local function card_token(value, suit)
					return (rank_codes[value] or tostring(value)) .. tostring(suit):sub(1, 1)
				end
				local tokens = {}
				for _, reel_entry in ipairs(valid_idol_cards) do
					tokens[#tokens + 1] = string.format(
						'"%s%s"', card_token(reel_entry.value, reel_entry.suit), tostring(reel_entry.count)
					)
				end
				local idol_payload = string.format(
					'{"roll":%s,"winner":"%s","cards":[%s]}',
					tostring(raw_random),
					card_token(idol_card.base.value, idol_card.base.suit),
					table.concat(tokens, ',')
				)
				sendDebugMessage('IDOL_ROLL::' .. love.data.encode('string', 'base64', idol_payload), 'IdolAlgo')

				-- Also into the replay log, so the website sees idol rolls from a
				-- server-stored match, not only from an uploaded Lovely log.
				if MPAPI.RLOGCodes and MPAPI.RLOGCodes.idol_roll and MPAPI.replay.is_active() then
					local card_tokens = {}
					for _, reel_entry in ipairs(valid_idol_cards) do
						card_tokens[#card_tokens + 1] = card_token(reel_entry.value, reel_entry.suit) .. tostring(reel_entry.count)
					end
					MPAPI.RLOGCodes.idol_roll:write(
						raw_random,
						card_token(idol_card.base.value, idol_card.base.suit),
						card_tokens
					)
				end
				break
			end
		end
		return
	end
	return _original_reset_idol_card()
end
