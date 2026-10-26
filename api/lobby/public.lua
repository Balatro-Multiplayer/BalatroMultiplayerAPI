-- Public lobby entry points: create and join (hosted on Nakama, see
-- api/lobby/nakama.lua), and offline local lobbies.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

MPAPI.create_lobby = function(mod_id, opts)
	return L.nakama_create_lobby(mod_id, opts or {})
end

-- Create a lobby that exists only on this client: no server lobby is ever
-- allocated. It satisfies the same interface as
-- a networked lobby (metadata, players, actions, gamemode instance, leave) but
-- everything is handled in-process. Use this for solo flows (e.g. practice) so
-- there is no server-side lobby that can be orphaned if the client never leaves.
MPAPI.create_local_lobby = function(mod_id, opts)
	opts = opts or {}
	local conn = MPAPI.get_connection()
	local player_id = (conn and conn.player_id) or 'local_player'

	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = player_id,
		connection = conn,
		is_host = true,
		max_players = opts.max_players or 1,
		metadata = opts.metadata or {},
		local_mode = true,
		type = 'private',
	})

	-- Register ourselves as the only player.
	lobby._players[player_id] = {
		id = player_id,
		displayName = (conn and conn.display_name) or 'You',
		is_away = false,
	}

	L.current = lobby

	-- Mirror the async create/join callbacks: fire 'connected' on the next event
	-- tick so the caller can attach handlers (setup_lobby_events, on('connected'))
	-- before they run.
	G.E_MANAGER:add_event(Event({
		func = function()
			if L.current == lobby and not lobby._destroyed then
				lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
				if MPAPI._internal.on_lobby_connected then
					MPAPI._internal.on_lobby_connected(lobby)
				end
			end
			return true
		end,
	}))

	return lobby
end

MPAPI.join_lobby = function(mod_id, code)
	return L.nakama_join_lobby(mod_id, code)
end

MPAPI.get_current_lobby = function()
	return L.current
end

-- Takes the seat in the lobby the server kept without making it the current lobby, and holds
-- what the server sends until L.attach_detached (api/playback/rejoin.lua). Returns the lobby;
-- on_ready(lobby) runs on the first snapshot.
MPAPI._internal.create_detached_lobby = function(lobby_data, on_ready)
	return L.nakama_rejoin_detached(lobby_data, on_ready)
end

-- Rejoins the lobby this player still has a seat in (the reconnect prompt);
-- on_ready(lobby) runs once its state is in.
MPAPI._internal.create_reconnected_lobby = function(lobby_data, on_ready)
	L.nakama_rejoin_lobby(lobby_data, on_ready)
end
