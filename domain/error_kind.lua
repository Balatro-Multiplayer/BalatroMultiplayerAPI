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
	-- A ranked queue attempt was refused because the launcher's anti-cheat
	-- supervision channel isn't active/healthy (see
	-- api/matchmaking/api.lua's queue() and anticheat/launcher_channel.lua).
	ANTICHEAT_REQUIRED = 'anticheat_required',
}
