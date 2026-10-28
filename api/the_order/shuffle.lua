-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
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
	-- CONFIRMED LIVE BUG, fixed by the `next(_t)` check: vanilla's own pseudorandom_element
	-- (functions/misc_functions.lua) explicitly guards `if #keys == 0 then return nil, nil end`
	-- -- this override dropped that guard. With an empty `_t`, the for loop below never runs, so
	-- is_joker/is_p_card stay at their initialized `true` default (nothing to disprove
	-- them), taking the joker/playing-card branch anyway with zero real entries: `keys` ends up
	-- {}, and `keys[1].k` crashes outright ("attempt to index a nil value") instead of the
	-- graceful `nil, nil` vanilla itself would return. Reproduced live via a real production
	-- match crash log: Hex's own deferred (0.4s-delayed) eligible-joker-selection callback
	-- (card.lua) calls this with `self.eligible_editionless_jokers` as `_t` -- non-empty at the
	-- moment Hex is played (Card:can_use_consumeable's own gate requires that), but the pool can
	-- legitimately empty out during that 0.4s window (e.g. another effect destroying/selling the
	-- only eligible joker before the delayed callback fires) -- a real race, not a hypothetical
	-- one. Falling through to the original implementation for an empty `_t` matches vanilla's own
	-- safe behavior exactly, and is a no-op change for every non-empty call (this override's
	-- normal case, untouched).
	if seed and MPAPI.should_use_the_order() and next(_t) ~= nil then
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
