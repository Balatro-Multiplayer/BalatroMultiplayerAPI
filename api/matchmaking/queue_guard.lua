-- Blocks starting a singleplayer run while a matchmaking search is active, and
-- provides the shared queue-guard mechanism consumer mods reuse for their own
-- queue-conflicting actions (e.g. creating/joining a lobby). Bug: nothing
-- stopped a queued player from clicking Play -> New Run (or Continue / a
-- Challenge) -- the run tore down the main menu while the search stayed active
-- server-side with no feedback. Maintainer verdict: not possible while queued.
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

-- Shared gate for any queue-conflicting entry point. If the local player is
-- searching, stash the blocked call as a replay closure and show the leave-or-
-- stay overlay instead of running it; returns true so the caller aborts.
-- Otherwise returns false and the caller proceeds normally. The overlay's
-- "Leave Queue & Continue" leaves every handle and invokes the stashed closure.
--
-- IMPORTANT: `replay` must re-enter the caller's OWN complete entry point, not a
-- lower-level primitive. The start_run wrap below replays the wrapped
-- G.FUNCS.start_run (a complete flow). A consumer guarding its lobby buttons
-- must replay its own MP.pvp_join_lobby / create function -- NOT MPAPI.join_lobby
-- directly, which would join server-side but skip the consumer's post-join setup
-- (lobby mirror + UI transition), stranding the player outside the lobby. Since
-- the replay re-enters a guarded entry point, is_queued() is false by then so it
-- proceeds; if the leave somehow didn't take, it re-blocks.
function MPAPI.matchmaking.guard_queued(replay)
	if not MPAPI.matchmaking.is_queued() then
		return false
	end
	mm.pending_action = replay
	G.SETTINGS.paused = true
	MPAPI.queue_guard_overlay:as_overlay()
	return true
end

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
	-- The replay closure re-enters the wrapper (not _start_run_ref) so the gate
	-- re-checks on the way through, matching the lobby entry points.
	if MPAPI.matchmaking.guard_queued(function() return G.FUNCS.start_run(e, args) end) then
		return
	end
	return _start_run_ref(e, args)
end
