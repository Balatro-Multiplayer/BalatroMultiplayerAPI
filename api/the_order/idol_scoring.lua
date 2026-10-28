-- Pure: The Order's scoring for The Idol. Groups the deck by (rank, suit) and sorts the groups
-- by how close each is to TARGET_COPIES exact copies, counting what the player could still do
-- to get there (suit changers, Strength) and the quality of the copies they hold. The sort sets
-- the order of the weighted pick in reset_idol_card (idol.lua), which rolls and writes the
-- result. Every number below is part of that order, so changing one changes which card wins.
MPAPI._internal.the_order = MPAPI._internal.the_order or {}

local TARGET_COPIES = 5

-- Every copy of the rank group (face ranks, or ranks 2 to 5) above the deck's average share.
local GROUP_SURPLUS_WEIGHT = 0.05
local FACE_GROUP_FACTOR = 1.1

-- At or above TARGET_COPIES: count and quality only.
local COPY_WEIGHT_AT_TARGET = 1.0
local QUALITY_WEIGHT_AT_TARGET = 1.0

-- Below TARGET_COPIES: progress, plus what could close the gap.
local COPY_WEIGHT_BELOW_TARGET = 2.0
local QUALITY_WEIGHT_BELOW_TARGET = 0.5
local SUIT_CHANGE_WEIGHT = 0.8
local SUIT_CHANGE_MAX = 3 -- the most cards one suit-changer Tarot converts
local STRENGTH_WEIGHT = 0.7
local STRENGTH_MAX = 2 -- the most cards one Strength raises

-- Sock and Buskin retriggers face cards and Hack retriggers 2 to 5, so with enough copies the
-- group is worth one red seal more per copy.
local RETRIGGER_MIN_COPIES = 3
local RETRIGGER_MAX_COPIES = 5

local function is_wild(card)
	return card.ability and card.ability.effect == 'Wild Card'
end

local function edition_weight(card)
	local e = card.edition
	if not e then return 0.0 end
	if e.polychrome then return 0.50 end
	if e.glass then return 0.50 end -- some mods track glass as an edition, not an enhancement
	if e.holo then return 0.25 end
	if e.foil then return 0.25 end
	return 0.0
end

local function enhancement_weight(card)
	local eff = card.ability and card.ability.effect
	if eff == 'Glass Card' then return 0.50 end
	if eff == 'Lucky Card' then return 0.01 end
	if eff == 'Bonus Card' then return 0.01 end
	if eff == 'Mult Card' then return 0.01 end
	return 0.0
end

local function seal_weight(card)
	if card.seal == 'Red' then return 1.0 end
	return 0.0
end

-- 'face', 'low' (nominal 2 to 5) or nil.
local function rank_group(rank)
	if not rank then return nil end
	if rank.face then return 'face' end
	if rank.nominal and rank.nominal >= 2 and rank.nominal <= 5 then return 'low' end
	return nil
end

local function round_to_nearest_05(x)
	return math.floor(x * 20 + 0.5) / 20
end

local function index_of(keys)
	local index = {}
	for i, key in ipairs(keys) do index[key] = i end
	return index
end

-- One entry per (rank, suit) in the deck, Stone Cards left out. `card` is the first copy seen.
local function group_by_rank_and_suit(deck)
	local by_key = {}
	local candidates = {}
	for _, card in ipairs(deck) do
		if card.ability.effect ~= 'Stone Card' then
			local key = card.base.value .. '_' .. card.base.suit
			local entry = by_key[key]
			if not entry then
				entry = { card = card, value = card.base.value, suit = card.base.suit, count = 0, cards = {}, wild_count = 0 }
				by_key[key] = entry
				candidates[#candidates + 1] = entry
			end
			entry.count = entry.count + 1
			entry.cards[#entry.cards + 1] = card
			if is_wild(card) then entry.wild_count = entry.wild_count + 1 end
		end
	end
	return candidates, by_key
end

-- deck: the playing cards. ranks: { order = rank keys in rank order, by_key = rank key ->
-- { face, nominal } }. suit_order: suit keys in suit order. jokers: { sock_and_buskin, hack },
-- true when the player holds it. Returns the candidates, best first, each
-- { card, value, suit, count }; empty when no card qualifies.
MPAPI._internal.the_order.rank_idol_candidates = function(deck, ranks, suit_order, jokers)
	local candidates, by_key = group_by_rank_and_suit(deck)
	if #candidates == 0 then return candidates end

	local rank_index = index_of(ranks.order)
	local suit_index = index_of(suit_order)

	local rank_totals, wild_by_rank = {}, {}
	local distinct_ranks, total_cards = 0, 0
	for _, entry in ipairs(candidates) do
		local r = entry.value
		if not rank_totals[r] then distinct_ranks = distinct_ranks + 1 end
		rank_totals[r] = (rank_totals[r] or 0) + entry.count
		wild_by_rank[r] = (wild_by_rank[r] or 0) + entry.wild_count
		total_cards = total_cards + entry.count
	end
	local mean_per_rank = total_cards / distinct_ranks

	-- A group scores on its copies above the share the average rank would give it.
	local group_pool, group_ranks = { face = 0, low = 0 }, { face = 0, low = 0 }
	for rank_key, total in pairs(rank_totals) do
		local group = rank_group(ranks.by_key[rank_key])
		if group then
			group_pool[group] = group_pool[group] + total
			group_ranks[group] = group_ranks[group] + 1
		end
	end
	local function group_surplus(group)
		return math.max(0.0, group_pool[group] - round_to_nearest_05(mean_per_rank * group_ranks[group]))
	end
	local group_score = {
		face = GROUP_SURPLUS_WEIGHT * FACE_GROUP_FACTOR * group_surplus('face'),
		low = GROUP_SURPLUS_WEIGHT * group_surplus('low'),
	}
	local retriggered = { face = jokers.sock_and_buskin, low = jokers.hack }

	-- Wraps: the rank before the first is the last.
	local function previous_rank_key(rank_key)
		local idx = rank_index[rank_key]
		if not idx then return nil end
		if idx == 1 then return ranks.order[#ranks.order] end
		return ranks.order[idx - 1]
	end

	for _, entry in ipairs(candidates) do
		local rank_key = entry.value
		local group = rank_group(ranks.by_key[rank_key])

		-- Wild cards of this rank in other suits count as copies.
		local wild_elsewhere = (wild_by_rank[rank_key] or 0) - entry.wild_count
		local effective_count = entry.count + wild_elsewhere

		local rank_score = group and group_score[group] or 0.0
		local seal_score, edition_score = 0.0, 0.0
		for _, card in ipairs(entry.cards) do
			seal_score = seal_score + seal_weight(card)
			edition_score = edition_score + edition_weight(card) + enhancement_weight(card)
		end
		if effective_count >= RETRIGGER_MIN_COPIES and group and retriggered[group] then
			seal_score = seal_score + math.min(effective_count, RETRIGGER_MAX_COPIES)
		end
		local quality = seal_score + edition_score

		entry.reached_target = effective_count >= TARGET_COPIES
		if entry.reached_target then
			entry.total_score = (COPY_WEIGHT_AT_TARGET * effective_count) + rank_score
				+ (quality * QUALITY_WEIGHT_AT_TARGET)
		else
			local needed = TARGET_COPIES - effective_count

			-- Same rank, other suits, not wild: a suit changer can turn them into copies.
			local convertible = (rank_totals[rank_key] or 0) - entry.count - wild_elsewhere
			local suit_change = SUIT_CHANGE_WEIGHT * math.min(SUIT_CHANGE_MAX, math.max(0.0, convertible), needed)

			-- One rank lower, same suit (wilds in any suit count): Strength can raise them.
			local below = 0
			local prev_rank = previous_rank_key(rank_key)
			if prev_rank then
				local neighbor = by_key[prev_rank .. '_' .. entry.suit]
				local neighbor_wild = neighbor and neighbor.wild_count or 0
				below = (neighbor and neighbor.count or 0) + (wild_by_rank[prev_rank] or 0) - neighbor_wild
			end
			local strength = STRENGTH_WEIGHT * math.min(STRENGTH_MAX, below, needed)

			entry.total_score = (COPY_WEIGHT_BELOW_TARGET * effective_count) + suit_change + strength + rank_score
				+ (quality * QUALITY_WEIGHT_BELOW_TARGET)
		end
	end

	-- Each (rank, suit) appears once, so rank and suit always settle a tie.
	table.sort(candidates, function(a, b)
		if a.reached_target ~= b.reached_target then return a.reached_target end
		if a.total_score ~= b.total_score then return a.total_score > b.total_score end
		local a_rank, b_rank = rank_index[a.value] or 0, rank_index[b.value] or 0
		if a_rank ~= b_rank then return a_rank > b_rank end
		return suit_index[a.suit] > suit_index[b.suit]
	end)
	return candidates
end
