-- The actual field-mutation core. One uniform mechanism across every pool: capture the literal
-- original value of each field touched (not just a boolean -- vanilla's own built-in challenges
-- define `.unlocked` as a function closing over the real profile's progress, see the `targets()`
-- comment below), then restore that exact value on revert. Never resets to a hardcoded
-- true/false, since that would permanently destroy a real closure.
--
-- Deliberately does NOT touch anything inside G.PROFILES[G.SETTINGS.profile] (no .all_unlocked,
-- .challenges_unlocked, .deck_usage, ...) -- that table is dumped to profile.jkr in full,
-- unconditionally, on every save (game.lua's Game:save_progress), so writing into it here would
-- make the fake unlock state permanent and impossible to fully undo. See save_guard.lua for the
-- other half of this safety story (never letting a save observe these fields at all).
-- One exception: clear_progress_caches below calls set_discover_tallies, which writes the
-- profile's collection counts. It puts the old values back in the same call, with no yield in
-- between, so no save can observe the write.
-- Defensive re-guard, not just state.lua's: load order between files in this directory isn't
-- guaranteed (e.g. "snapshot.lua" sorts before "state.lua"), same reasoning api/matchmaking/'s
-- files each re-guard MPAPI._internal.mm.
MPAPI._internal.unlock_overlay = MPAPI._internal.unlock_overlay or {}
local ov = MPAPI._internal.unlock_overlay

-- Every pool + field set touched. `match(key)` (if present) restricts which keys in an
-- otherwise-mixed pool (G.P_CENTERS holds jokers/vouchers/decks/editions/consumables together)
-- get which fields -- editions/consumables have no `.unlocked` concept at all, only `.discovered`.
local function targets()
	return {
		-- Jokers (j_*), Vouchers (v_*), Decks/Backs (b_*): real lock + discovery + alert.
		{
			obj = G.P_CENTERS,
			match = function(k) return k:match('^j_') or k:match('^v_') or k:match('^b_') end,
			fields = { 'unlocked', 'discovered', 'alerted' },
		},
		-- Editions (e_*), Tarot/Spectral/Planet consumables (c_*, p_*): no lock concept, only
		-- discovery/alert (confirmed: these centers never declare an `.unlocked` field at all).
		{
			obj = G.P_CENTERS,
			match = function(k) return k:match('^e_') or k:match('^c_') or k:match('^p_') end,
			fields = { 'discovered', 'alerted' },
		},
		{ obj = G.P_BLINDS, fields = { 'discovered', 'alerted' } },
		{ obj = G.P_TAGS, fields = { 'discovered', 'alerted' } },
		{ obj = G.P_SEALS, fields = { 'discovered', 'alerted' } },
		-- Stakes: G.P_STAKES and SMODS.Stakes are the same table object. Read by
		-- SMODS.stake_is_unlocked, confirmed never written to any save file -- safe to touch
		-- directly. Known limitation: stake_is_unlocked short-circuits on the real profile's
		-- deck_usage table before ever checking this flag for a deck the player has never
		-- actually won on a real stake, so this can still show locked in that specific case.
		-- Fixing that would require writing into G.PROFILES, which is exactly what this file
		-- must never do -- accepted as-is; nothing in PvP/SPDRN currently checks this anyway.
		{ obj = SMODS.Stakes, fields = { 'unlocked' } },
		-- Challenges: SMODS.challenge_is_unlocked checks `challenge.unlocked` directly (function,
		-- boolean, or absent) before falling back to the real profile's challenges_unlocked
		-- counter. Setting it on the live object here, and restoring the exact original value
		-- (often a function) on revert, never touches that profile counter.
		{ obj = G.CHALLENGES, fields = { 'unlocked' } },
	}
end

-- Captures the real value of every targeted field, once. Idempotent: if a snapshot already
-- exists, does nothing -- calling this again while the overlay is already active must never
-- re-capture the FAKE values as if they were the real ones (see save_guard.lua, which calls
-- apply()/revert() around every save while the overlay is active).
MPAPI._internal.unlock_overlay.capture = function()
	if ov.snapshot then
		return
	end
	local snap = {}
	for _, t in ipairs(targets()) do
		for k, v in pairs(t.obj or {}) do
			if not t.match or t.match(k) then
				for _, field in ipairs(t.fields) do
					snap[#snap + 1] = { obj = v, field = field, value = v[field] }
				end
			end
		end
	end
	ov.snapshot = snap
end

-- Cosmetic-only, cached collection-progress stats (misc_functions.lua's set_profile_progress/
-- set_discover_tallies), recomputed on every transition so a stale count from before it can't
-- linger on screen. G.PROGRESS is dropped and re-derived lazily next time something reads it.
-- DISCOVER_TALLIES is rebuilt now: only the vanilla collection menu rebuilds it itself, and
-- Steamodded's consumables page (and others) index it directly, so leaving it nil crashes them.
-- The rebuild suppresses set_discover_tallies' side effects (achievement checks and profile
-- writes, which would otherwise record the overlay's fake unlocks).
local function clear_progress_caches()
	G.DISCOVER_TALLIES = nil
	G.PROGRESS = nil
	if not set_discover_tallies then
		return
	end
	local profile = G.PROFILES and G.SETTINGS and G.PROFILES[G.SETTINGS.profile]
	local saved_scores, saved_progress
	if profile then
		saved_scores = profile.high_scores and profile.high_scores.collection
		saved_scores = saved_scores and { amt = saved_scores.amt, tot = saved_scores.tot }
		saved_progress = profile.progress and profile.progress.discovered
	end
	local real_check = check_for_unlock
	check_for_unlock = function() end
	local ok = pcall(set_discover_tallies)
	check_for_unlock = real_check
	if profile then
		if saved_scores then
			profile.high_scores.collection.amt = saved_scores.amt
			profile.high_scores.collection.tot = saved_scores.tot
		end
		if profile.progress then
			profile.progress.discovered = saved_progress
		end
	end
	if not ok then
		G.DISCOVER_TALLIES = nil
	end
end

MPAPI._internal.unlock_overlay.apply = function()
	MPAPI._internal.unlock_overlay.capture()
	for _, entry in ipairs(ov.snapshot) do
		entry.obj[entry.field] = true
	end
	clear_progress_caches()
end

MPAPI._internal.unlock_overlay.revert = function()
	if not ov.snapshot then
		return
	end
	for _, entry in ipairs(ov.snapshot) do
		entry.obj[entry.field] = entry.value
	end
	ov.snapshot = nil
	clear_progress_caches()
end
