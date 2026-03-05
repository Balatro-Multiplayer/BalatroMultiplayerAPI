-- Animated multiplayer edition colour
-- Drifts between violet and magenta within the purple family
MPAPI.C = MPAPI.C or {}
MPAPI.C.MP_EDITION = { 0.55, 0.30, 0.70, 1 }

local _game_update_ref = Game.update
function Game:update(dt)
	_game_update_ref(self, dt)
	local t = self.TIMERS.REAL
	local c = MPAPI.C.MP_EDITION
	local s = math.sin(t * 0.7)
	c[1] = 0.72 + 0.08 * s
	c[2] = 0.45 + 0.05 * s
	c[3] = 0.64 - 0.08 * s
end

-- Returns a Joker card using the user's preferred joker id
-- Can be easily added to UI using { n = G.UIT.O, config = { object = card } }
-- card_parameters get added to the underlying card values
function MPAPI.create_account_avatar(card_parameters)
	local joker_id = MPAPI.connection_state.preferred_joker or 'j_joker'
	local center = G.P_CENTERS[joker_id] or G.P_CENTERS['j_joker']
	local card = Card(0, 0, G.CARD_W, G.CARD_H, G.P_CARDS.empty, center, card_parameters)
	card.states.drag.can = false
	card.states.hover.can = true
	card.states.click.can = true

	return card
end
