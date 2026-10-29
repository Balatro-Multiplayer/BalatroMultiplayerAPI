-- Closed set of failure categories an MPAPI boundary can report. Carried as the
-- `kind` field of an error value (see domain/result.lua) so callers branch on the
-- category rather than parsing a message string.
MPAPI.ErrorKind = {
	NOT_CONNECTED = 'not_connected',
	NO_TOKEN = 'no_token',
	NOT_IN_LOBBY = 'not_in_lobby',
	NO_ACTIVE_MATCH = 'no_active_match',
	VALIDATION = 'validation',
	TRANSPORT = 'transport',
	AUTH_FAILED = 'auth_failed',
	TIMEOUT = 'timeout',
	SERVER = 'server',
	-- The Nakama lobby refused an action (the reason is the message: e.g.
	-- not_host, not_all_ready, rate_limited). See api/action/dispatch.lua.
	ACTION_REJECTED = 'action_rejected',
	-- The server has no handler for an MPAPI action this client sends (it
	-- predates the feature, e.g. Setup in api/setup.lua).
	SERVER_TOO_OLD = 'server_too_old',
	-- A ranked queue attempt was refused because the launcher's anti-cheat
	-- supervision channel isn't active/healthy (see
	-- api/matchmaking/api.lua's queue() and anticheat/launcher_channel.lua).
	ANTICHEAT_REQUIRED = 'anticheat_required',
	-- Already-queued Ranked player got dequeued because the server's
	-- post-join ranked_readiness challenge came back (or timed out)
	-- reporting BET itself isn't on the latest version. Takes priority
	-- over RANKED_MODS_OUTDATED when both are true, since updating BET
	-- also resolves stale mods on the next launch - see
	-- api/matchmaking/dispatch.lua.
	RANKED_LAUNCHER_OUTDATED = 'ranked_launcher_outdated',
	-- Same challenge, but BET itself was current - one or more active
	-- Ranked-legal mods' on-disk hash didn't match what's currently
	-- ranked-legal. Fixed by relaunching through BET (RunController's
	-- pre-launch pipeline redeploys automatically), not by updating BET
	-- itself.
	RANKED_MODS_OUTDATED = 'ranked_mods_outdated',
	-- The account's standing (domain/standing.lua) refuses the queue: a mod
	-- outside the allowlist, no mod report yet, or ranked without a launcher
	-- verdict. See api/connection/standing.lua's MPAPI.can_queue.
	MODS_NOT_ALLOWED = 'mods_not_allowed',
	MODS_UNREPORTED = 'mods_unreported',
	INTEGRITY_REQUIRED = 'integrity_required',
	VERSION_MISMATCH = 'version_mismatch',
}
