-- §18.2 Trigger Contexts: a generic, single dispatch point for "an opponent's
-- action just happened" -- any joker/consumable can react to it via its own
-- calculate(self, card, context), the same way vanilla cards already react to
-- the game's own built-in contexts, instead of each card needing its own
-- base-game patch AND its own bespoke receive handler.
--
-- The capture point (noticing "X happened" on the ACTING player's own client)
-- still has to hook wherever that base-game event actually lives -- that part
-- doesn't go away, and isn't what this replaces. What this replaces is
-- everything downstream of that: instead of the capture site calling a
-- uniquely-named per-card broadcast function, and that card owning a bespoke
-- ActionType/receive just to hear it, the capture site calls this once with a
-- plain context-shaped table, and every card watching for it (via its own
-- ordinary calculate) just reacts -- exactly like any other context flag.
--
-- Flag names passed in `flags` should be opponent-scoped (e.g.
-- `opponent_selling_card`, not `selling_card`) to avoid colliding with
-- vanilla's own same-named LOCAL context flags (context.selling_card,
-- context.buying_card, etc. already mean something different: "this is
-- happening on MY OWN client right now", not "an opponent told me it
-- happened to them").
MPAPI.ActionType({
	key = 'mpapi_opponent_context',
	on_receive = function(action_type, from_player_id, params)
		local context = params or {}
		context.from = from_player_id

		for _, area in ipairs({ G.jokers, G.consumeables }) do
			if area and area.cards then
				for _, card in ipairs(area.cards) do
					if card.calculate then
						card:calculate(context)
					end
				end
			end
		end
	end,
})

-- Called from a capture point on the ACTING player's own client (e.g. a
-- sell_card/shop/reroll patch) the instant something happens that other
-- players' cards might care about. `flags` is a plain table of opponent-
-- scoped context fields, exactly like the table a vanilla context check
-- expects.
function MPAPI.broadcast_opponent_context(flags)
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if not lobby then
		return
	end
	lobby:action(MPAPI.ActionTypes['mpapi_opponent_context']):broadcast(flags or {})
end
