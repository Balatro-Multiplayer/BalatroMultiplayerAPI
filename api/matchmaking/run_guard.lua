-- Blocks vanilla singleplayer run-start while a matchmaking search is active.
-- Bug: nothing stopped a queued player from clicking Play -> New Run (or
-- Continue / a Challenge); the run would tear down the main menu while the
-- queue stayed active server-side with no feedback. Maintainer verdict: you
-- should not be able to start a run at all while queued.
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

-- G.FUNCS.start_run is the single vanilla chokepoint every "enter a run"
-- flow funnels through -- New Run and Continue (via start_setup_run), Challenges
-- (via start_challenge_run), the first-launch tutorial run, and the in-run
-- "Start New Run" restart button all call it directly. It is also the function
-- that actually tears down the menu (G.E_MANAGER:clear_queue(), wipe_on/off)
-- and calls Game:start_run -- gating here, before any of that runs, catches
-- every one of those entry points with a single wrap and leaves the menu
-- completely untouched when blocked.
local _start_run_ref = G.FUNCS.start_run
G.FUNCS.start_run = function(e, args)
	if MPAPI.matchmaking.is_queued() then
		-- Stash the blocked action so the overlay's "Leave Queue & Play" can
		-- replay it after leaving. Replay goes back through this wrapper, so the
		-- gate is re-checked -- if the leave somehow didn't take, it re-blocks
		-- instead of starting a run while queued.
		mm.pending_run = { e = e, args = args }
		G.SETTINGS.paused = true
		MPAPI.queue_guard_overlay:as_overlay()
		return
	end
	return _start_run_ref(e, args)
end
