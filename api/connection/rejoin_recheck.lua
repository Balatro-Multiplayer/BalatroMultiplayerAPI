-- A rejoin refusal that only says "verification pending" gets one fresh look
-- before the player sees it: Launcher verification starts again and a verdict
-- is awaited. This holds the cooldown that stops a server that keeps saying
-- "pending" from looping the client; ui/rejoin_refused_overlay.lua is the view.
MPAPI.rejoin_recheck = MPAPI.rejoin_recheck or {}
local R = MPAPI.rejoin_recheck

-- Seconds after a recheck ended during which a pending refusal is not
-- rechecked again.
R.COOLDOWN_SECONDS = 20

local rechecked_at = nil

function R.reset()
	rechecked_at = nil
end

-- Whether a refusal should be rechecked now: it is pending, it did not
-- already follow a wait for the verdict, and the last recheck is not recent.
function R.due(refusal, already_waited)
	if refusal.code ~= MPAPI.RejoinRefusalCode.VERIFICATION_PENDING or already_waited then
		return false
	end
	return rechecked_at == nil or os.time() - rechecked_at >= R.COOLDOWN_SECONDS
end

-- cb(outcome (MPAPI.VerdictOutcome)) once the new verdict lands or the wait
-- times out.
function R.run(cb)
	MPAPI._internal.conn.verify_again(MPAPI.standing.VERDICT_WAIT_SECONDS, function(outcome)
		rechecked_at = os.time()
		cb(outcome)
	end)
end
