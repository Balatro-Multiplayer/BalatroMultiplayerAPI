-- Run from the API root: luajit tests/booster_recording_test.lua
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
local checks = 0
local function check(ok, message)
	checks = checks + 1
	assert(ok, message)
end
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
print(('ok   %d checks'):format(checks))
