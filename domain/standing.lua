-- The account's queue standing, as the server works it out from the
-- session's mod report (BalatroMultiplayerServer nakama/src/standing). Closed
-- sets; keep them in step with the server's.

-- verified: a launcher (or dev) verdict, whatever the mods.
-- valid: only allowed mods reported, or enforcement is off.
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
}

-- Why a matchmade game refused a join or rejoin (the `standing_refused:`
-- match_join error).
MPAPI.RejoinRefusalCode = {
	MODS_NOT_ALLOWED = 'mods_not_allowed',
	MODS_UNREPORTED = 'mods_unreported',
	VERIFICATION_PENDING = 'verification_pending',
}
