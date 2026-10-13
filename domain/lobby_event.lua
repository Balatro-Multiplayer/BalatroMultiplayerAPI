-- Event names a lobby object fires to its listeners. The PLAYER_*, METADATA_CHANGED,
-- HOST_CHANGED and LOBBY_CLOSED values double as the server event-message `type`
-- field (see api/lobby/events.lua); CONNECTED/DISCONNECTED/ERROR/PLAYER_INFO are
-- client-side only. Values are the wire strings, so external listeners that pass
-- string literals to lobby:on(...) keep working.
MPAPI.LobbyEvent = {
	CONNECTED = 'connected',
	DISCONNECTED = 'disconnected',
	ERROR = 'error',
	-- Client-side only, never a server LobbyEvent.type: set by MPAPI.set_player_ready
	-- (api/lobby/ready.lua), called by any gamemode's own ready-broadcast handler.
	PLAYER_READY_CHANGED = 'player_ready_changed',
	-- Client-side only: the server started (or restarted) the game
	-- (mpapi_start_game / mpapi_restart_game, Nakama lobbies). Args: { run_id,
	-- seed, stake, options, players, restarted? }. See api/action/builtin.lua.
	GAME_STARTED = 'game_started',
	-- The server ended the game: every result is in, the result clock ran
	-- out, or the host abandoned it (Nakama lobbies). Also a server event
	-- type. Args: { run_id, status, placements }.
	GAME_ENDED = 'game_ended',
	-- Client-side only: the server is restarting (Nakama lobbies). The
	-- connection drops next and the lobby is rejoined, under the same code,
	-- once the server is back. Args: { grace_seconds }.
	SERVER_RESTARTING = 'server_restarting',
	PLAYER_JOINED = 'player_joined',
	PLAYER_LEFT = 'player_left',
	PLAYER_KICKED = 'player_kicked',
	PLAYER_DISCONNECTED = 'player_disconnected',
	PLAYER_RECONNECTED = 'player_reconnected',
	PLAYER_INFO = 'player_info',
	METADATA_CHANGED = 'metadata_changed',
	HOST_CHANGED = 'host_changed',
	LOBBY_CLOSED = 'lobby_closed',
}
