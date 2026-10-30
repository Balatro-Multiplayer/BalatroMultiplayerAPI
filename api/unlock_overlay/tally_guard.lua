-- Keeps the overlay's fake discoveries out of the profile when the collection counts are rebuilt.
-- The base game's set_discover_tallies (misc_functions.lua) writes the counts into
-- G.PROFILES[...].high_scores.collection and .progress.discovered, then calls check_for_unlock
-- with them. The vanilla Collection menu calls it every time it opens, so while the overlay is on
-- it would record 100% discovered in the profile (saved on the next save_progress, which
-- save_guard.lua cannot stop: it only reverts the fields in the snapshot) and could fire the
-- discover-amount unlocks and achievements.
MPAPI._internal.unlock_overlay = MPAPI._internal.unlock_overlay or {}
local ov = MPAPI._internal.unlock_overlay

local function active_profile()
	return G.PROFILES and G.SETTINGS and G.PROFILES[G.SETTINGS.profile]
end

-- Rebuilds G.DISCOVER_TALLIES with the base game's set_discover_tallies, then puts back the
-- profile fields it wrote. check_for_unlock is stubbed for the call. No yield happens in between,
-- so no save can observe the write. Raises the base game's error, if any, after the restore.
MPAPI._internal.unlock_overlay.rebuild_discover_tallies = function()
	local profile = active_profile()
	local saved_collection, saved_discovered
	if profile then
		local collection = profile.high_scores and profile.high_scores.collection
		saved_collection = collection and { amt = collection.amt, tot = collection.tot }
		saved_discovered = profile.progress and profile.progress.discovered
	end
	local real_check = check_for_unlock
	check_for_unlock = function() end
	local ok, err = pcall(ov.real_set_discover_tallies)
	check_for_unlock = real_check
	if profile then
		if saved_collection then
			profile.high_scores.collection.amt = saved_collection.amt
			profile.high_scores.collection.tot = saved_collection.tot
		end
		if profile.progress then
			profile.progress.discovered = saved_discovered
		end
	end
	if not ok then
		error(err, 0)
	end
end

if set_discover_tallies and not ov.real_set_discover_tallies then
	ov.real_set_discover_tallies = set_discover_tallies
	function set_discover_tallies(...)
		if ov.snapshot then
			return ov.rebuild_discover_tallies()
		end
		return ov.real_set_discover_tallies(...)
	end
end
