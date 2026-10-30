-- Credit to @MathIsFun_ for creating TheOrder, which this hook is a modified copy of.
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
	if MPAPI.should_use_the_order() or MPAPI._internal.the_order.voucher_queue_follows_the_order() then
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
	if MPAPI.should_use_the_order() or MPAPI._internal.the_order.voucher_queue_follows_the_order() then
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
