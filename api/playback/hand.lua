-- Replay helper for the hand of cards, shared by every mod that replays a recording (PvP, SPDRN)
-- and by the generic opcodes in api/replay/generic_codes.lua.

MPAPI.playback = MPAPI.playback or {}

MPAPI.playback.HAND_READY_TIMEOUT_SECONDS = 10

-- True while a played or discarded hand is still being replaced: the cards just played are
-- gone and the refill is not dealt. The event queue can be empty in this time (the refill is
-- drawn by the state machine, not by a queued event), so the driver would dispatch the next
-- play at once and find no card to select.
function MPAPI.playback.hand_is_refilling()
	local S = G.STATES
	if G.STATE == S.HAND_PLAYED or G.STATE == S.DRAW_TO_HAND then
		return true
	end
	return G.STATE == S.SELECTING_HAND and not (G.hand and G.hand.cards and #G.hand.cards > 0)
end

-- Runs `fn` (a play or a discard) at once when the hand is dealt. While the refill is pending,
-- pauses the driver, waits for it (bounded, so a replay that cannot deal a hand cannot hang),
-- runs `fn` and resumes. `wait_for(predicate, callback)` is the mod's own one-shot condition poll.
function MPAPI.playback.with_hand_ready(ctx, fn, wait_for)
	if not MPAPI.playback.hand_is_refilling() then
		fn()
		return
	end
	local driver = ctx.driver
	if driver then
		driver:pause()
	end
	local timeout = MPAPI.playback.HAND_READY_TIMEOUT_SECONDS
	local deadline = love.timer.getTime() + timeout
	wait_for(function()
		if not MPAPI.playback.hand_is_refilling() then
			return true
		end
		if love.timer.getTime() >= deadline then
			MPAPI.playback.wait_gave_up('[replay] hand never dealt after ' .. timeout .. 's, acting anyway')
			return true
		end
		return false
	end, function()
		fn()
		if driver then
			driver:play()
		end
	end)
end
