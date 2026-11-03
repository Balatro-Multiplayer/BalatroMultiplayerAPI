-- The account's queue standing, as the server works it out from the
-- session's mod report (BalatroMultiplayerServer nakama/src/standing). Closed
-- sets; keep them in step with the server's.

-- verified: a launcher (or dev) verdict, whatever the mods.
-- valid: only allowed mods reported (the check is always on).
-- none: unreported, or a mod outside the allowlist.
MPAPI.Standing = {
	VERIFIED = 'verified',
	VALID = 'valid',
	NONE = 'none',
}

-- Why a standing is none.
MPAPI.StandingReason = {
	UNREPORTED = 'unreported',
	MODS_NOT_ALLOWED = 'mods_not_allowed',
}

-- The two matchmaking queues a standing gates. Private lobbies are never gated.
MPAPI.QueueKind = {
	CASUAL = 'casual',
	RANKED = 'ranked',
}

-- Why the client may not queue (MPAPI.can_queue) or the server refused a
-- ticket (QUEUE_CANCELLED's `code`).
MPAPI.QueueRefusalCode = {
	MODS_NOT_ALLOWED = 'mods_not_allowed',
	MODS_UNREPORTED = 'mods_unreported',
	INTEGRITY_REQUIRED = 'integrity_required',
	-- The server found players of one game on different mod versions (PvP:
	-- everyone needs the same MultiplayerPvP X.Y.Z). Nakama's `VERSION_MISMATCH`.
	VERSION_MISMATCH = 'version_mismatch',
}

-- Why a matchmade game refused a join or rejoin (the `standing_refused:`
-- match_join error).
MPAPI.RejoinRefusalCode = {
	MODS_NOT_ALLOWED = 'mods_not_allowed',
	MODS_UNREPORTED = 'mods_unreported',
	VERIFICATION_PENDING = 'verification_pending',
	-- A definite failed launcher verdict: waiting or retrying cannot help.
	VERIFICATION_FAILED = 'verification_failed',
}

-- Why a launcher verdict failed, as the INTEGRITY notification's `reason`.
-- DEFINITE_FAILURES mirrors DEFINITE_FAILURE_REASONS in
-- BalatroMultiplayerServer nakama/src/integrity.ts: the reasons the server
-- treats as a final "no". A timeout is not one.
MPAPI.IntegrityFailureReason = {
	WRONG_RESPONSE = 'wrong_response',
	REFUSED = 'refused',
	TIMEOUT = 'timeout',
}
MPAPI.IntegrityFailureReason.DEFINITE_FAILURES = {
	[MPAPI.IntegrityFailureReason.WRONG_RESPONSE] = true,
	[MPAPI.IntegrityFailureReason.REFUSED] = true,
}

-- How a wait for a launcher verdict ended (C.verify_again in api/connection/standing.lua).
MPAPI.VerdictOutcome = {
	VERIFIED = 'verified',
	FAILED = 'failed',
	TIMED_OUT = 'timed_out',
}
