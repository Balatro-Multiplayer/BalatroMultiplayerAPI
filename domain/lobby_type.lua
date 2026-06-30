-- Lobby visibility/competitive category a GameMode is sized for. Used as the keys
-- of a GameMode's min_players/max_players tables and by get_min_players /
-- get_max_players.
MPAPI.LobbyType = {
	PUBLIC = 'public',
	PRIVATE = 'private',
	RANKED = 'ranked',
}
