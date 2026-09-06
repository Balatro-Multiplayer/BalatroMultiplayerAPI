-- Credit to @MathIsFun_ for creating TheOrder, which the queue hooks below are a modified copy of.

-----------------------------
-- Flag
-----------------------------

-- §20: generic extension points, same idiom as MPAPI.register_mod_isolation
-- (api/layers/pool_gating.lua) -- a platform file exposes a registry, and a
-- consuming mod (PvP, or any future one) registers its own predicate, instead
-- of this file branching on a PVP-specific global directly.
MPAPI._order_gates = MPAPI._order_gates or {}
function MPAPI.register_order_gate(fn)
	MPAPI._order_gates[#MPAPI._order_gates + 1] = fn
end

MPAPI._voucher_queue_gates = MPAPI._voucher_queue_gates or {}
function MPAPI.register_voucher_queue_gate(fn)
	MPAPI._voucher_queue_gates[#MPAPI._voucher_queue_gates + 1] = fn
end

function MPAPI.should_use_the_order()
	if MPAPI.is_layer_active('the_order') then return true end
	for _, gate in ipairs(MPAPI._order_gates) do
		if gate() then return true end
	end
	return false
end

-- Some consumers (PvP's major-league ruleset) want the culled/stable voucher
-- queue below without the full Order treatment, so the voucher hooks
-- additionally gate on this.
local function mp_major_league()
	for _, gate in ipairs(MPAPI._voucher_queue_gates) do
		if gate() then return true end
	end
	return false
end

-----------------------------
-- Layer definition
-----------------------------

MPAPI.Layer('the_order', {
	reworked_tags = {
		'tag_uncommon',
		'tag_rare',
	},
})

-----------------------------
-- ReworkCenter registrations
-----------------------------

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

-----------------------------
-- Queue hook helpers
-----------------------------

function MPAPI.ante_based()
	if MPAPI.should_use_the_order() then return 0 end
	return G.GAME.round_resets.ante
end

function MPAPI.order_round_based(ante_based)
	if MPAPI.should_use_the_order() then
		return G.GAME.round_resets.ante
			.. (G.GAME.blind.config.blind.key or '')
			.. (G.GAME.blind_on_deck or '')
	end
	if ante_based then return MPAPI.ante_based() end
	return ''
end

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

-----------------------------
-- Queue hooks (from TheOrder.lua)
-----------------------------

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

-- Patches idol RNG to weight selection by count of identical cards in deck.
local _original_reset_idol_card = reset_idol_card
function reset_idol_card()
	if MPAPI.should_use_the_order() then
		G.GAME.current_round.idol_card.rank = 'Ace'
		G.GAME.current_round.idol_card.suit = 'Spades'

		local count_map = {}
		local valid_idol_cards = {}
		for _, v in ipairs(G.playing_cards) do
			if v.ability.effect ~= 'Stone Card' then
				local key = v.base.value .. '_' .. v.base.suit
				if not count_map[key] then
					count_map[key] = { count = 0, card = v }
					table.insert(valid_idol_cards, count_map[key])
				end
				count_map[key].count = count_map[key].count + 1
			end
		end
		if #valid_idol_cards == 0 then return end

		local value_order = {}
		for i, rank in ipairs(SMODS.Rank.obj_buffer) do value_order[rank] = i end
		local suit_order = {}
		for i, suit in ipairs(SMODS.Suit.obj_buffer) do suit_order[suit] = i end

		table.sort(valid_idol_cards, function(a, b)
			if a.count ~= b.count then return a.count > b.count end
			local a_suit, b_suit = a.card.base.suit, b.card.base.suit
			if suit_order[a_suit] ~= suit_order[b_suit] then return suit_order[a_suit] < suit_order[b_suit] end
			return value_order[a.card.base.value] < value_order[b.card.base.value]
		end)

		local total_weight = 0
		for _, entry in ipairs(valid_idol_cards) do total_weight = total_weight + entry.count end

		local raw_random = pseudorandom('idol' .. G.GAME.round_resets.ante)
		local threshold = 0
		for _, entry in ipairs(valid_idol_cards) do
			threshold = threshold + (entry.count / total_weight)
			if raw_random < threshold then
				local idol_card = entry.card
				MPAPI.sendDebugMessage(
					'(Idol) Selected ' .. idol_card.base.value .. ' of ' .. idol_card.base.suit
						.. ' weight=' .. entry.count .. '/' .. total_weight
				)
				G.GAME.current_round.idol_card.rank = idol_card.base.value
				G.GAME.current_round.idol_card.suit = idol_card.base.suit
				G.GAME.current_round.idol_card.id = idol_card.base.id
				break
			end
		end
		return
	end
	return _original_reset_idol_card()
end

-- Patches mail rank RNG to weight selection by rank frequency in deck.
local _original_reset_mail_rank = reset_mail_rank
function reset_mail_rank()
	if MPAPI.should_use_the_order() then
		G.GAME.current_round.mail_card.rank = 'Ace'

		local count_map = {}
		local valid_ranks = {}
		local value_order = {}
		for i, rank in ipairs(SMODS.Rank.obj_buffer) do value_order[rank] = i end

		for _, v in ipairs(G.playing_cards) do
			if v.ability.effect ~= 'Stone Card' then
				local val = v.base.value
				if not count_map[val] then
					count_map[val] = { count = 0, example_card = v }
					table.insert(valid_ranks, { value = val, count = 0, example_card = v })
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
		for _, entry in ipairs(valid_ranks) do total_weight = total_weight + count_map[entry.value].count end

		local raw_random = pseudorandom('mail' .. G.GAME.round_resets.ante)
		local threshold = 0
		for _, entry in ipairs(valid_ranks) do
			local weight = count_map[entry.value].count / total_weight
			threshold = threshold + weight
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

-- Patch seal polling to use a single game-long queue when The Order is active.
local _pollseal = SMODS.poll_seal
function SMODS.poll_seal(args)
	if MPAPI.should_use_the_order() then
		local a = G.GAME.round_resets.ante
		G.GAME.round_resets.ante = 0
		G.GAME.round_resets.mp_real_ante = a
		local ret = _pollseal(args)
		G.GAME.round_resets.ante = a
		G.GAME.round_resets.mp_real_ante = nil
		return ret
	end
	return _pollseal(args)
end

-- Patch voucher queue to draw from a stable culled pool.
local function get_culled(_pool)
	local culled = {}
	for i = 1, #_pool, 2 do
		local first = _pool[i]
		local second = _pool[i + 1]
		if second == nil then
			culled[#culled + 1] = (first ~= 'UNAVAILABLE') and first or 'UNAVAILABLE'
		elseif first ~= 'UNAVAILABLE' and second ~= 'UNAVAILABLE' then
			culled[#culled + 1] = first
			culled[#culled + 1] = second
		elseif first ~= 'UNAVAILABLE' then
			culled[#culled + 1] = first
		elseif second ~= 'UNAVAILABLE' then
			culled[#culled + 1] = second
		else
			culled[#culled + 1] = 'UNAVAILABLE'
		end
	end
	return culled
end

-- Whether `culled` still has at least one entry this call could legally land on: not
-- 'UNAVAILABLE' (both halves of that pair are exhausted/locked) and not already claimed by an
-- earlier iteration of this same get_next_vouchers call (`spawn`). A cheap linear scan, not an
-- RNG draw -- safe to call before every iteration without perturbing the pseudorandom_element
-- sequence the loop below depends on for its exact draw order.
local function has_available_voucher(culled, spawn)
	for _, v in ipairs(culled) do
		if v ~= 'UNAVAILABLE' and not spawn[v] then
			return true
		end
	end
	return false
end

local _nextvouchers = SMODS.get_next_vouchers
function SMODS.get_next_vouchers(vouchers)
	if MPAPI.should_use_the_order() or mp_major_league() then
		vouchers = vouchers or { spawn = {} }
		local _pool = get_current_pool('Voucher')
		local culled = get_culled(_pool)
		for i = #vouchers + 1, math.min(
			SMODS.size_of_pool(_pool),
			G.GAME.starting_params.vouchers_in_shop + (G.GAME.modifiers.extra_vouchers or 0)
		) do
			-- DEFENSIVE FIX for a real (not just theoretical) dead end found via code review,
			-- NOT YET LIVE-CONFIRMED as the trigger for a separately-reported freeze (see that
			-- investigation's own notes) -- flagging the confidence level explicitly since this
			-- file otherwise reserves stronger language for live-verified fixes.
			--
			-- Per call, `culled`'s count of real (non-'UNAVAILABLE') entries always exactly
			-- equals SMODS.size_of_pool(_pool) (get_culled above only ever collapses a pair to
			-- a single 'UNAVAILABLE' placeholder when BOTH halves are unavailable, so every
			-- available raw entry survives into `culled` one-for-one) -- so a single call
			-- starting from an empty `vouchers` table can never legitimately run out, since the
			-- outer loop above never asks for more than that same size_of_pool(_pool) count.
			--
			-- The gap is cross-call: `vouchers` is NOT always fresh. `game.lua`'s shop-render
			-- path calls `SMODS.get_next_vouchers(G.GAME.current_round.voucher)`, re-passing an
			-- ALREADY-PARTIALLY-FILLED table from an earlier ante's call, to top it up when
			-- vouchers_in_shop/extra_vouchers has since grown. `vouchers.spawn` still marks
			-- every voucher chosen back then, but `culled`/`_pool` here are recomputed fresh
			-- against CURRENT availability -- if the pool's available set hasn't grown (or
			-- shrunk) enough to cover both the old spawned entries AND the new top-up target,
			-- every remaining entry in the current `culled` can be simultaneously
			-- 'UNAVAILABLE' or already in the old `vouchers.spawn`, with the outer loop still
			-- expecting one more. Without this guard, the while loop below has no way out --
			-- every reseed attempt (including `it > 1000`) can only ever land back on that same
			-- exhausted set, spinning forever with no yield point. Since this runs synchronously
			-- inside Game:start_run/shop-render (not inside any Event queue), that's not just a
			-- hang MPAPI.sendWarnMessage could report from mid-loop -- love2d's own main loop
			-- never gets back to processing input/network until the calling frame returns, so a
			-- true infinite loop here freezes the whole process, unrecoverably.
			--
			-- Stopping early here instead of guaranteeing termination is the deliberately safe
			-- tradeoff: a shop with fewer vouchers than requested is a minor, visible cosmetic
			-- gap; an unbounded spin is a total, unrecoverable process freeze.
			if not has_available_voucher(culled, vouchers.spawn) then
				MPAPI.sendWarnMessage(
					'[the_order] get_next_vouchers: culled voucher pool exhausted after '
						.. tostring(#vouchers) .. '/' .. tostring(i - 1)
						.. ' -- stopping early instead of spinning forever'
				)
				break
			end
			local center = pseudorandom_element(culled, pseudoseed('Voucher0'))
			local it = 1
			while center == 'UNAVAILABLE' or vouchers.spawn[center] do
				it = it + 1
				center = pseudorandom_element(culled, pseudoseed('Voucher0'))
				if it > 1000 then
					center = pseudorandom_element(culled, pseudoseed('Voucher0' .. it))
				end
			end
			vouchers[#vouchers + 1] = center
			vouchers.spawn[center] = true
		end
		return vouchers
	end
	return _nextvouchers(vouchers)
end

local _nextvoucherkey = get_next_voucher_key
function get_next_voucher_key(_from_tag)
	if MPAPI.should_use_the_order() or mp_major_league() then
		local _pool = get_current_pool('Voucher')
		local culled = get_culled(_pool)
		-- Unlike SMODS.get_next_vouchers above, this one doesn't need the same guard: `_pool`
		-- comes straight from vanilla's get_current_pool, which unconditionally synthesizes a
		-- single real fallback entry (e.g. 'v_blank') whenever the raw pool would otherwise be
		-- empty -- so `culled` derived from it can never end up with zero real entries. This
		-- function only ever draws once per call (no `vouchers.spawn`-style cross-call table
		-- reuse), so the "ran out mid-call" scenario the other function guards against doesn't
		-- apply here either.
		local center = pseudorandom_element(culled, pseudoseed('Voucher0'))
		local it = 1
		while center == 'UNAVAILABLE' do
			it = it + 1
			center = pseudorandom_element(culled, pseudoseed('Voucher0'))
			if it > 1000 then
				center = pseudorandom_element(culled, pseudoseed('Voucher0' .. it))
			end
		end
		return center
	end
	return _nextvoucherkey(_from_tag)
end

-----------------------------
-- Shuffle / element selection
-----------------------------

local stdval = {
	centers = {
		c_base     = 0,
		m_stone    = 106,
		m_bonus    = 107,
		m_mult     = 108,
		m_wild     = 109,
		m_gold     = 110,
		m_lucky    = 111,
		m_steel    = 112,
		m_glass    = 113,
	},
	seals = {
		Gold   = 122,
		Blue   = 131,
		Purple = 140,
		Red    = 149,
	},
	editions = {
		foil        = 157,
		holo        = 192,
		polychrome  = 227,
	},
}

local function give_stdval(card)
	card.mp_stdval = 0 + (stdval.centers[card.config.center_key] or 0)
	card.mp_stdval = card.mp_stdval + (stdval.seals[card.seal or 'nil'] or 0)
	card.mp_stdval = card.mp_stdval + (stdval.editions[card.edition and card.edition.type or 'nil'] or 0)
end

local function give_shufflevals(tbl, seed, joker)
	local tables = {}
	for k, v in pairs(tbl) do
		local key
		if joker then
			key = v.config.center.key
		else
			give_stdval(v)
			key = v.config.center.key == 'm_stone' and 'Stone' or v.base.suit .. v.base.id
		end
		tables[key] = tables[key] or {}
		tables[key][#tables[key] + 1] = v
	end

	if seed and type(seed) == 'string' then seed = pseudoseed(seed) end
	local true_seed = pseudorandom(seed)

	for k, v in pairs(tables) do
		if joker then
			table.sort(v, function(a, b) return a.sort_id < b.sort_id end)
		else
			table.sort(v, function(a, b) return a.mp_stdval > b.mp_stdval end)
		end
		local mega_seed = k .. true_seed
		for _, card in ipairs(v) do
			G._MP_UNSAVED_PRNG = true
			card.mp_shuffleval = pseudorandom(mega_seed)
			G._MP_UNSAVED_PRNG = false
		end
		G.GAME.pseudorandom[mega_seed] = nil
	end
end

-- Rework shuffle RNG to be more consistent between players. Only takes over when
-- the CALLER passed an explicit seed: give_shufflevals' whole point is deriving
-- a shared, keyed seed (pseudoseed(seed)) so host and guest land on the same
-- shuffle order despite each having their own hand/joker list state -- with no
-- seed given, that guarantee doesn't apply anyway, and falling through to
-- _orig_pseudoshuffle here means it gets vanilla's OWN default RNG advance
-- (a deterministic continuation of the shared anonymous pseudorandom stream),
-- not a substitute we have to invent. Confirmed live: this used to fall back to
-- `seed or math.random()` -- genuinely non-deterministic, process-local entropy
-- with no relation to the match seed at all -- firing hundreds of times in the
-- first round alone. That silently made every ORDER-ruleset match's own joker/
-- card selection non-reproducible even in real gameplay (host and guest could
-- diverge on exactly the "more consistent between players" selections this
-- file exists to synchronize), and made replaying any such match from its
-- recorded seed impossible in principle, not just buggy -- confirmed by
-- replaying a real production match log, which desynced from its own
-- recording within the first round and eventually crashed deep in vanilla
-- scoring code once a replayed play/discard fed it a hand that no longer
-- matched what was actually dealt.
local _orig_pseudoshuffle = pseudoshuffle
function pseudoshuffle(list, seed)
	if seed and MPAPI.should_use_the_order() then
		local is_p_card = true
		for k, v in pairs(list) do
			if is_p_card and not (type(v) == 'table' and v.ability
				and (v.ability.set == 'Default' or v.ability.set == 'Enhanced'))
			then
				is_p_card = false
			end
		end
		if is_p_card then
			give_shufflevals(list, seed)
			table.sort(list, function(a, b) return a.mp_shuffleval > b.mp_shuffleval end)
			return
		end
	end
	return _orig_pseudoshuffle(list, seed)
end

-- Make pseudorandom_element selecting a joker or playing card more consistent
-- between players -- see pseudoshuffle above for why this only takes over when
-- an explicit seed was actually given.
local _orig_pseudorandom_element = pseudorandom_element
function pseudorandom_element(_t, seed, args)
	if seed and MPAPI.should_use_the_order() then
		local is_joker, is_p_card = true, true
		for k, v in pairs(_t) do
			if is_joker and not (type(v) == 'table' and v.ability and v.ability.set == 'Joker') then
				is_joker = false
			end
			if is_p_card and not (type(v) == 'table' and v.ability
				and (v.ability.set == 'Default' or v.ability.set == 'Enhanced'))
			then
				is_p_card = false
			end
		end
		if is_joker or is_p_card then
			local keys = {}
			for k, v in pairs(_t) do keys[#keys + 1] = { k = k, v = v } end
			give_shufflevals(_t, seed, is_joker)
			table.sort(keys, function(a, b) return a.v.mp_shuffleval > b.v.mp_shuffleval end)
			local key = keys[1].k
			return _t[key], key
		end
	end
	return _orig_pseudorandom_element(_t, seed, args)
end

-----------------------------
-- Diagnostics (replay-only)
-----------------------------

-- Entry/exit logging (via MPAPI.sendWarnMessage, which is confirmed to flush/surface even when
-- code called shortly after it hangs -- the original investigation's own "stalled at cursor..."
-- messages relied on exactly this) around two vanilla RNG-pool functions that run synchronously
-- inside Game:start_run at the exact `run_died -> run_info -> select_blind` restart boundary
-- where a real, reproducible, CPU-pegged freeze was found (Ghost Deck/stake 8/Misprint/Hex,
-- cursor ~204-206). Code review found this codebase's own get_next_vouchers override has a real
-- (now-fixed, see above) termination gap, but could NOT confirm it's reachable from that exact
-- boundary (its own fresh-per-call path there is provably safe -- only a later, table-reusing
-- shop-render call site isn't). get_next_tag_key/generate_starting_seed were also reviewed and
-- look structurally safe by inspection, but "looks safe by inspection" is exactly what the
-- get_next_vouchers case also looked like before the cross-call scenario was found -- so this
-- adds a cheap, zero-behavior-change trace instead of asserting confidence pure code review
-- couldn't actually earn. If the freeze recurs, whichever "entering" line has no matching
-- "exiting" line pinpoints the stuck call directly, without another blind multi-hour live sweep.
--
-- Gated on an active replay/rejoin driver so this adds zero log volume (and negligible overhead
-- -- one love.timer.getTime() pair per call) for real, live play.
local function _diag_during_replay()
	return next(MPAPI.playback._active_drivers) ~= nil
end

local _diag_gen_starting_seed = generate_starting_seed
function generate_starting_seed(...)
	if not _diag_during_replay() then
		return _diag_gen_starting_seed(...)
	end
	MPAPI.sendWarnMessage('[diagnostic] entering generate_starting_seed')
	local ret = _diag_gen_starting_seed(...)
	MPAPI.sendWarnMessage('[diagnostic] exiting generate_starting_seed')
	return ret
end

local _diag_next_tag_key = get_next_tag_key
function get_next_tag_key(...)
	if not _diag_during_replay() then
		return _diag_next_tag_key(...)
	end
	MPAPI.sendWarnMessage('[diagnostic] entering get_next_tag_key')
	local ret = _diag_next_tag_key(...)
	MPAPI.sendWarnMessage('[diagnostic] exiting get_next_tag_key: ' .. tostring(ret))
	return ret
end
