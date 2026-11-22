-- Contract test for api/playback/shop.lua: shop actions recorded and replayed.
local T = dofile('tests/support.lua')
local check = T.check

-- A shop Booster is recorded once as open_pack, and replays open it without a second charge.
T.part(function()
	local function noop() end
	local events, active, buys, uses = {}, true, 0, 0
	Card = { is = function(_, class) return class == Card end, sell_card = noop }
	CardArea = { update = noop }
	SMODS = {}
	ease_dollars = noop
	G = {
		FUNCS = {
			buy_from_shop = function() buys = buys + 1 end,
			use_card = function() uses = uses + 1; return 'opened' end,
		},
		shop_booster = { cards = {} }, consumeables = { cards = {} }, pack_cards = { cards = {} },
	}
	MPAPI = {
		OPCODE = setmetatable({}, { __index = function(_, key) return key:lower() end }),
		RLOGCodes = {},
		replay = {
			is_active = function() return active end,
			card_ref = function(card) return { -1, card.ability.set, card.key } end,
			highlighted_hand_indices = function() return {} end,
			card_refs = function() return {} end,
		},
	}
	function MPAPI.RLOG_CODE(def)
		def.record = function(self, args) events[#events + 1] = { key = self.key, args = args } end
		MPAPI.RLOGCodes[def.key] = def
	end
	dofile('api/replay/area_utils.lua')
	dofile('api/playback/registry.lua')
	dofile('api/playback/shop.lua')
	dofile('api/replay/generic_codes.lua')
	local function card(set, area)
		local c = setmetatable({ ability = { name = set, set = set }, key = 'test', cost = 4, area = area }, { __index = Card })
		area.cards = { c }
		return c
	end

	local pack = card('Booster', G.shop_booster)
	check(G.FUNCS.use_card({ config = { ref_table = pack } }) == 'opened', 'OPEN must still call vanilla')
	check(#events == 1 and events[1].key == 'open_pack', 'the real OPEN callback must record a pack purchase')
	local args = events[1].args
	check(args[1] == 2 and args[2] == 1 and args[3][2] == 'Booster' and args[4] == 4, 'record the pack area, slot, identity and cost')
	events = {}
	G.FUNCS.buy_from_shop({ config = { id = 'buy_and_use', ref_table = pack } })
	check(buys == 0 and uses == 2, 'replay purchase must open directly without a second charge')
	check(#events == 1 and events[1].key == 'open_pack', 'the replay-compatible path must record only once')

	events = {}
	G.FUNCS.use_card({ config = { ref_table = card('Joker', G.pack_cards) } })
	check(#events == 1 and events[1].key == 'pack_pick', 'a pack selection must remain a pack_pick')
	events = {}
	G.FUNCS.use_card({ config = { ref_table = card('Tarot', G.consumeables) } })
	check(#events == 1 and events[1].key == 'use', 'a normal consumable must remain a use')
	events = {}
	G.shop_jokers = { cards = {} }
	G.FUNCS.buy_from_shop({ config = { ref_table = card('Joker', G.shop_jokers) } })
	check(buys == 1 and #events == 1 and events[1].key == 'buy', 'ordinary purchases must still use vanilla buying')

	events, active = {}, false
	check(G.FUNCS.buy_from_shop({ config = { ref_table = pack } }) == 'opened', 'playback must open while recording is disabled')
	check(#events == 0 and buys == 1, 'playback must neither record nor invoke the ordinary purchase')
	local dispatched
	MPAPI.playback.register_handler('pvp', 'open_pack', function(args) dispatched = { 'open_pack', args } end)
	MPAPI.playback.register_handler('pvp', 'use', function(args) dispatched = { 'use', args } end)
	local legacy_ref = { -2, 'Booster', 'p_buffoon_normal_1' }
	local legacy_args = { 1, {}, legacy_ref, {} }
	MPAPI.playback.dispatch('pvp', 'use', legacy_args, {})
	check(dispatched[1] == 'open_pack' and dispatched[2][1] == 2 and dispatched[2][2] == 1, 'older pack USE must replay as a shop pack opening')
	check(dispatched[2][3] == legacy_ref and legacy_args[3] == legacy_ref, 'preserve identity without rewriting the stored log')
	MPAPI.playback.dispatch('pvp', 'use', { 1, {}, { -3, 'Tarot', 'c_hermit' } }, {})
	check(dispatched[1] == 'use', 'an older consumable USE must not become a pack opening')
	MPAPI.playback.dispatch('pvp', 'use', { 1, {} }, {})
	check(dispatched[1] == 'use', 'do not guess when an older log has no card identity')
end)

-- A Spectral or Joker that creates or removes Jokers writes one joker_hit naming them.
T.part(function()
	local function noop() end
	local events, queue = {}, {}
	Card = { is = function(_, class) return class == Card end, sell_card = noop, calculate_joker = noop }
	CardArea = { update = noop }
	SMODS = {}
	ease_dollars = noop
	Event = function(def) return def end
	G = {
		FUNCS = { buy_from_shop = noop, use_card = noop, cash_out = noop },
		E_MANAGER = { add_event = function(_, event) queue[#queue + 1] = event end },
		jokers = { cards = {} },
		shop_booster = { cards = {} }, consumeables = { cards = {} }, pack_cards = { cards = {} },
	}
	MPAPI = {
		OPCODE = setmetatable({}, { __index = function(_, key) return key:lower() end }),
		RLOGCodes = {},
		replay = {
			is_active = function() return true end,
			card_ref = noop,
			area_enum = noop,
			index_in_area = noop,
			highlighted_hand_indices = function() return {} end,
			card_refs = function() return {} end,
			joker_token = function(card)
				local key = card and card.config and card.config.center and card.config.center.key
				if not key then return nil end
				if card.edition and card.edition.type then return key .. '|' .. card.edition.type end
				return key
			end,
		},
	}
	function MPAPI.RLOG_CODE(def)
		def.record = function(self, args) events[#events + 1] = { key = self.key, args = args } end
		MPAPI.RLOGCodes[def.key] = def
	end
	dofile('api/replay/area_utils.lua')
	dofile('api/playback/registry.lua')
	dofile('api/playback/shop.lua')

	local function joker(key, extra)
		local c = setmetatable({
			config = { center = { key = key } },
			ability = { name = key, set = 'Joker' },
		}, { __index = Card })
		for k, v in pairs(extra or {}) do c[k] = v end
		return c
	end

	-- What each vanilla effect does to the lineup, run when the card is used.
	local effect
	Card.use_consumeable = function() if effect then effect() end end
	Card.calculate_joker = function() if effect then effect() end end
	Card.sell_card = function() if effect then effect() end end
	dofile('api/replay/generic_codes.lua')

	local function flush()
		local pending = queue
		queue = {}
		for _, event in ipairs(pending) do event.func() end
	end
	local function hit()
		flush()
		local out = events[#events]
		events = {}
		return out
	end
	local function add(card) G.jokers.cards[#G.jokers.cards + 1] = card end
	local function consumable(key)
		return setmetatable({ config = { center = { key = key } }, ability = { name = key } }, { __index = Card })
	end

	-- Wraith adds one joker.
	G.jokers.cards = { joker('j_joker') }
	effect = function() add(joker('j_ceremonial')) end
	consumable('c_wraith'):use_consumeable()
	local e = hit()
	check(e and e.key == 'joker_hit', 'Wraith must write a joker_hit')
	check(e.args[1] == 'wraith' and e.args[2][1] == 'j_ceremonial' and #e.args[3] == 0, 'Wraith source and created joker')

	-- Ankh: an eternal joker with the same key as the copied one sits first. The
	-- cards Ankh dissolved are the ones reported, not a guess by key.
	local eternal = joker('j_joker', { ability = { eternal = true } })
	local kept = joker('j_joker')
	local gone = joker('j_blueprint', { edition = { type = 'foil' } })
	G.jokers.cards = { eternal, kept, gone }
	effect = function()
		gone.getting_sliced = true
		gone.dissolve = 0
		add(joker('j_joker'))
	end
	consumable('c_ankh'):use_consumeable()
	e = hit()
	check(e.args[1] == 'ankh' and e.args[2][1] == 'j_joker', 'Ankh reports the copy')
	check(#e.args[3] == 1 and e.args[3][1] == 'j_blueprint|foil', 'Ankh reports only the dissolved card')

	-- Two Riff-Raffs back to back: no joker is reported twice.
	local riff = { ability = { name = 'Riff-raff' }, config = { center = { key = 'j_riff_raff' } } }
	setmetatable(riff, { __index = Card })
	G.jokers.cards = { riff }
	effect = function() add(joker('j_a')); add(joker('j_b')) end
	riff:calculate_joker({ setting_blind = true })
	effect = function() add(joker('j_c')); add(joker('j_d')) end
	riff:calculate_joker({ setting_blind = true })
	flush()
	check(#events == 1, 'a joker is never reported by two hits')
	check(events[1].args[1] == 'riffraff' and #events[1].args[2] == 4, 'the hits together report each new joker once')
	events = {}

	-- Riff-Raff with no room adds nothing, so nothing is written.
	effect = noop
	riff:calculate_joker({ setting_blind = true })
	check(hit() == nil, 'a Riff-Raff with no room writes nothing')

	-- A mature Invisible Joker copies a joker as it is sold; an immature one does not.
	local invisible = joker('j_invisible')
	G.jokers.cards = { invisible, joker('j_joker') }
	effect = function() add(joker('j_joker')) end
	invisible:sell_card()
	e = hit()
	check(e and e.args[1] == 'invisible' and e.args[2][1] == 'j_joker', 'mature Invisible writes its copy')
	G.jokers.cards = { invisible }
	effect = noop
	invisible:sell_card()
	check(hit() == nil, 'immature Invisible writes nothing')
end)

T.done('shop_replay_test')
