-- Entry/exit logging (via MPAPI.sendWarnMessage, which is confirmed to flush/surface even when
-- code called shortly after it hangs -- the original investigation's own "stalled at cursor..."
-- messages relied on exactly this) around two vanilla RNG-pool functions that run synchronously
-- inside Game:start_run at the exact `run_died -> run_info -> select_blind` restart boundary
-- where a real, reproducible, CPU-pegged freeze was found (Ghost Deck/stake 8/Misprint/Hex,
-- cursor ~204-206). Code review found this codebase's own get_next_vouchers override has a real
-- (now fixed, see api/the_order/vouchers.lua) termination gap, but could NOT confirm it's reachable from that exact
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
