-- The `type` field of a matchmaking message published to player/<id>/matchmaking.
MPAPI.MatchmakingMessage = {
	MATCH_FOUND = 'match_found',
	MATCH_RECONNECT = 'match_reconnect',
	MATCH_RESOLVED = 'match_resolved',
	-- Pushed when a post-queue-join ranked_readiness challenge (see
	-- anticheat/launcher_channel.lua) is refused, fails, or times out -
	-- the server has already dequeued the player by the time this
	-- arrives. `reason` is 'launcher_outdated' or 'mods_outdated' - see
	-- api/matchmaking/dispatch.lua's handling.
	QUEUE_CANCELLED = 'queue_cancelled',
}
