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
