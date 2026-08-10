MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

-- Generic, gamemode-agnostic per-player ready flag on the lobby roster. Any
-- mod's ready-broadcast action handler calls this for every client (not just
-- the host) so core lobby UI (the card hover popup) can show a ready badge
-- without needing to know which gamemode's ready protocol is in play. Left
-- unset (nil) until a mod actually sends a ready action for that player --
-- ui/lobby.lua's hover popup is the one that decides how to render that: it
-- defaults nil to Not Ready in private lobbies, and hides the badge entirely
-- in public (matchmaking) lobbies regardless of this field.
function MPAPI.set_player_ready(lobby, player_id, ready)
	if not lobby or not player_id then
		return
	end
	lobby._players[player_id] = lobby._players[player_id] or { id = player_id }
	lobby._players[player_id].ready = ready and true or false
	lobby:_fire(MPAPI.LobbyEvent.PLAYER_READY_CHANGED, player_id, lobby._players[player_id].ready)
end
