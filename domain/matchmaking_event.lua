-- Event names a matchmaking handle fires to its listeners. Values are the wire
-- strings, so external listeners passing string literals to handle:on(...) keep
-- working.
MPAPI.MatchmakingEvent = {
	QUEUED = 'queued',
	MATCH_FOUND = 'match_found',
	LOBBY_READY = 'lobby_ready',
	LEFT = 'left',
	ERROR = 'error',
	MATCH_RESOLVED = 'match_resolved',
}
