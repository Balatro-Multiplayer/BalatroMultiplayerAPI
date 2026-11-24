-- Contract test for the instant queue ranges of the ranked matchmaker ticket:
-- a player at or above the floor (or at or below the ceiling) queues among
-- everyone in that range until they have waited the time the normal window
-- needs to reach the range's edge (times the range's multiplier), then the
-- normal window applies as well and the range grows past its edge. Run from the
-- MPAPI repository root:
-- luajit tests/instant_queue_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

-- The window call goes last: only the last argument of a call gives all its values.
local function window(message, want_lo, want_hi, lo, hi)
	check(lo == want_lo and hi == want_hi, message .. ': got ' .. tostring(lo) .. ', ' .. tostring(hi))
end

MPAPI = {}
dofile('api/matchmaking/api.lua')
local M = MPAPI.matchmaking

-- The normal window: 150, then +50 every 30 seconds, up to 600.
check(M.ranked_spread(0) == 150 and M.ranked_spread(30) == 200 and M.ranked_spread(1000) == 600, 'normal window')

-- Seconds the normal window needs to span a gap; a gap past the cap takes as long as the cap.
check(M.secs_to_span(0) == 0, 'no gap')
check(M.secs_to_span(150) == 0, 'the starting window spans 150')
check(M.secs_to_span(151) == 30, 'one step spans 151 to 200')
check(M.secs_to_span(300) == 90, '300 takes three steps')
check(M.secs_to_span(600) == 270, '600 takes nine steps')
check(M.secs_to_span(5000) == 270, 'past the cap takes the cap time')

local ranges = { floor = 1200, ceiling = 400, floorMultiplier = 1, ceilingMultiplier = 1 }

-- Which range a rating is in.
local side, edge, gap = M.instant_side(1500, ranges)
check(side == 'upper' and edge == 1200 and gap == 300, 'above the floor')
check(M.instant_side(1200, ranges) == 'upper', 'the floor itself is in the range')
side, edge, gap = M.instant_side(300, ranges)
check(side == 'lower' and edge == 400 and gap == 100, 'below the ceiling')
check(M.instant_side(400, ranges) == 'lower', 'the ceiling itself is in the range')
check(M.instant_side(800, ranges) == nil, 'between the ranges is in neither')
check(M.instant_side(1500, nil) == nil, 'no ranges')
check(M.instant_side(1500, { floor = {}, ceiling = {} }) == nil, 'an edge that is not a number is not set')
check(M.instant_side(1500, { floor = nil, ceiling = 400 }) == nil, 'only a ceiling set')

-- The second a range opens up.
check(M.instant_open_at(1500, ranges) == 90, 'normal time to the edge')
check(M.instant_open_at(1500, { floor = 1200, floorMultiplier = 2 }) == 180, 'a multiplier of 2 doubles it')
check(M.instant_open_at(1500, { floor = 1200, floorMultiplier = 0.5 }) == 45, 'a multiplier of 0.5 halves it')
check(M.instant_open_at(1250, ranges) == 0, 'near the edge it is open at once')
check(M.instant_open_at(2000, ranges) == 270, 'far above takes the cap time')
check(M.instant_open_at(800, ranges) == nil, 'no range, no opening')

-- Outside a range the window is the normal one.
window('normal at 0s', 650, 950, M.ranked_window(800, 0, ranges))
window('normal at 60s', 550, 1050, M.ranked_window(800, 60, ranges))

-- The upper range: everyone at or above the floor, no upper bound, until it opens up.
window('upper at 0s', 1200, nil, M.ranked_window(1500, 0, ranges))
window('upper just before it opens', 1200, nil, M.ranked_window(1500, 89, ranges))
window('upper when it opens', 1200, nil, M.ranked_window(1500, 90, ranges))
window('upper grows past the floor', 1150, nil, M.ranked_window(1500, 120, ranges))
window('upper past the cap of the extra growth', 750, nil, M.ranked_window(1500, 1000, ranges))
window('far above opens at the cap time', 1200, nil, M.ranked_window(2000, 270, ranges))
window('far above then grows', 1150, nil, M.ranked_window(2000, 300, ranges))
window('a multiplier of 2 holds it longer', 1200, nil, M.ranked_window(1500, 150, { floor = 1200, floorMultiplier = 2 }))
window('and opens to the normal window', 1050, nil, M.ranked_window(1500, 180, { floor = 1200, floorMultiplier = 2 }))

-- The lower range mirrors it.
window('lower at 0s', nil, 400, M.ranked_window(100, 0, ranges))
window('lower when it opens', nil, 400, M.ranked_window(100, 90, ranges))
window('lower grows past the ceiling', nil, 450, M.ranked_window(100, 120, ranges))
window('near the edge it is the normal window at once', nil, 450, M.ranked_window(300, 0, ranges))

-- Re-queue times.
check(M.next_requeue_at(10) == 30 and M.next_requeue_at(30) == 60, 'a step every 30s')
check(M.next_requeue_at(10, 20) == 20, 'an opening before the next step')
check(M.next_requeue_at(10, 45) == 30, 'an opening after the next step waits')
check(M.next_requeue_at(20, 10) == 30, 'an opening already past')
check(M.next_requeue_at(25, nil) == 30, 'no opening')

-- The ticket.
local opts = { mod_id = 'M', game_mode = 'ranked:standard', min_players = 2, max_players = 2 }
local base = '+properties.modId:M +properties.mode:standard +properties.kind:ranked'
check(M._nakama_ticket(opts, true, 1500, 300).query == base .. ' +properties.rating:>=1200 +properties.rating:<=1800', 'the normal window without ranges')
check(M._nakama_ticket(opts, true, 1500, nil, ranges, 0).query == base .. ' +properties.rating:>=1200', 'an upper bound is left off')
check(M._nakama_ticket(opts, true, 100, nil, ranges, 0).query == base .. ' +properties.rating:<=400', 'a lower bound is left off')
check(M._nakama_ticket(opts, true, 800, nil, ranges, 0).query == base .. ' +properties.rating:>=650 +properties.rating:<=950', 'the normal window between the ranges')
check(M._nakama_ticket(opts, true, 1500, nil, ranges, 0).numbers.rating == 1500, 'the ticket still carries the rating')
check(M._nakama_ticket(opts, false).query == '+properties.modId:M +properties.mode:standard +properties.kind:casual', 'a casual ticket is unchanged')

print('instant_queue_test: ' .. checks .. ' checks passed')
