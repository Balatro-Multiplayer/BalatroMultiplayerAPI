-- The lobby object factory and its lifecycle state. The active lobby pointer and
-- the helpers shared across the lobby files live on MPAPI._internal.lobby so they
-- cross files without load-order coupling.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

L.create_object = function(opts)
	local lobby = {
		code = opts.code,
		mod_id = opts.mod_id,
		is_host = opts.is_host or false,
		-- 'public' only for matchmaking-created lobbies (server-authoritative, set
		-- from the join snapshot's type); defaults to
		-- 'private' so the brief window before that response lands, and any local
		-- (offline/practice) lobby, both read as private -- gates the ready-status
		-- badge in ui/lobby.lua (hidden entirely for public/matchmaking lobbies).
		type = opts.type or 'private',
		max_players = opts.max_players or 16,
		player_id = opts.player_id,
		_connection = opts.connection,
		_metadata = opts.metadata or {},
		_player_state = nil,
		_players = {},
		_event_handlers = {},
		_destroyed = false,
		_gamemode_instance = nil,
		-- Offline lobbies have no server backing: metadata, player state, leave
		-- and actions are all handled in-process. See MPAPI.create_local_lobby.
		_local_mode = opts.local_mode or false,
		-- Every other lobby is hosted as a Nakama match: see api/lobby/nakama.lua.
		_nakama = opts.nakama or false,
		-- Server-owned game state (Nakama lobbies): { ready = {id=true},
		-- started = nil | { seed, stake, options }, setup = { open, results } }.
		-- See api/action/builtin.lua.
		_game = { ready = {}, started = nil, reported = {}, setup = { open = nil, results = {} } },
	}

	function lobby:on(event_name, handler)
		if not self._event_handlers[event_name] then
			self._event_handlers[event_name] = {}
		end
		local handlers = self._event_handlers[event_name]
		handlers[#handlers + 1] = handler
	end

	function lobby:_fire(event_name, ...)
		local handlers = self._event_handlers[event_name]
		if not handlers then
			return
		end
		for _, handler in ipairs(handlers) do
			local ok, err = pcall(handler, ...)
			if not ok then
				MPAPI.sendWarnMessage('Lobby event "' .. event_name .. '" handler error: ' .. tostring(err))
			end
		end
	end

	function lobby:set_metadata(tbl)
		if self._destroyed then
			return
		end
		if not self.is_host then
			self:_fire(MPAPI.LobbyEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'Only the host can set metadata'))
			return
		end
		-- Offline lobby: no server round-trip; merge locally and notify listeners.
		if self._local_mode then
			for k, v in pairs(tbl) do
				self._metadata[k] = v
			end
			self:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, self._metadata)
			return
		end
		-- The server merges it and broadcasts it back to everyone.
		local NL = MPAPI.networking.nakama_lobby
		NL.send(NL.ClientOp.SET_METADATA, { metadata = tbl })
	end

	function lobby:get_metadata()
		return self._metadata
	end

	function lobby:get_gamemode_instance()
		return self._gamemode_instance
	end

	-- A mod makes its gamemode instance when a match starts (or a host takes over) and hands it
	-- to the lobby here: the field behind it is the lobby's own.
	function lobby:set_gamemode_instance(instance)
		self._gamemode_instance = instance
	end

	function lobby:set_player_state(tbl)
		if self._destroyed then
			return
		end
		if self._local_mode then
			self._player_state = tbl
			return
		end
		local NL = MPAPI.networking.nakama_lobby
		NL.send(NL.ClientOp.SET_STATE, { state = tbl })
		self._player_state = tbl
	end

	function lobby:get_player_state()
		return self._player_state
	end

	function lobby:get_players()
		local result = {}
		for _, player in pairs(self._players) do
			result[#result + 1] = player
		end
		return result
	end

	-- Whether `player_id` is replaying its own run after a crash (the server
	-- tells everyone; see api/playback/rejoin.lua). Nothing waits for it.
	function lobby:is_player_catching_up(player_id)
		local player = self._players[player_id]
		return player ~= nil and player.catching_up == true
	end

	-- Tells the server this client is (or no longer is) catching up. The
	-- flag is sent again after a socket drop's rejoin (api/lobby/nakama.lua).
	function lobby:set_catching_up(catching_up)
		if self._destroyed or self._local_mode then
			return
		end
		self._catching_up = catching_up == true
		local NL = MPAPI.networking.nakama_lobby
		NL.send(NL.ClientOp.CATCHING_UP, { catchingUp = self._catching_up })
		local me = self._players[self.player_id]
		if me then
			me.catching_up = self._catching_up
		end
	end

	function lobby:leave()
		if self._destroyed then
			return
		end
		-- Offline lobby: nothing to tell the server; tear down locally.
		if self._local_mode then
			L.cleanup(self)
			self:_fire(MPAPI.LobbyEvent.DISCONNECTED)
			if MPAPI._internal.on_lobby_disconnected then
				MPAPI._internal.on_lobby_disconnected()
			end
			return
		end
		-- Tear down once the server has dropped us. Local teardown happens even
		-- if that failed; the server's grace period drops us then.
		if self._leaving then
			return
		end
		self._leaving = true
		MPAPI.networking.nakama_lobby.leave(function(err)
			if err then
				MPAPI.sendWarnMessage('[nakama_lobby] leave failed: ' .. tostring(err))
			end
			L.cleanup(self)
			self:_fire(MPAPI.LobbyEvent.DISCONNECTED)
			if MPAPI._internal.on_lobby_disconnected then
				MPAPI._internal.on_lobby_disconnected()
			end
		end)
	end

	lobby._pending_actions = {}

	-- The lobby's mod's action types, plus MPAPI's own (which every lobby
	-- has: mpapi_opponent_context, mpapi_ready, ...).
	lobby._action_types = {}
	for _, key in ipairs(MPAPI.ActionType.obj_buffer) do
		local at = MPAPI.ActionTypes[key]
		if at.mod and (at.mod.id == lobby.mod_id or at.mod.id == MPAPI.id) then
			lobby._action_types[key] = at
		end
	end

	function lobby:action(action_type)
		return MPAPI._internal.create_action_instance(self, action_type)
	end

	-- Server-refereed lobby flow (Nakama lobbies only; see api/action/builtin.lua).
	function lobby:set_ready(ready, cb)
		L.set_ready(self, ready, cb)
	end

	function lobby:start_game(opts, cb)
		L.start_game(self, opts, cb)
	end

	function lobby:is_game_started()
		return self._game.started ~= nil
	end

	-- When the server saw the race begin, on this client's clock (love.timer.getTime): the
	-- origin of a race clock that counts time away. nil until the race has begun, or when this
	-- lobby has not had a snapshot with the server's time.
	function lobby:get_race_started_local()
		local started = self._game.started
		return started and started.race_started_local or nil
	end

	function lobby:report_result(placements, cb)
		L.report_result(self, placements, cb)
	end

	function lobby:set_result_pending(pending, cb)
		L.set_result_pending(self, pending, cb)
	end

	function lobby:abandon_game(cb)
		L.abandon_game(self, cb)
	end

	function lobby:restart_game(cb)
		L.restart_game(self, cb)
	end

	-- See MPAPI.has_server_referee (api/action/builtin.lua).
	function lobby:has_server_referee()
		return MPAPI.has_server_referee(self)
	end

	return lobby
end

L.populate_initial_players = function(lobby, players)
	if not players then
		return
	end
	for _, p in ipairs(players) do
		if p.id then
			lobby._players[p.id] = {
				id = p.id,
				displayName = p.displayName,
				preferredJoker = p.preferredJoker,
				is_away = false,
			}
		end
	end
end

L.cleanup = function(lobby)
	if lobby._destroyed then
		return
	end
	lobby._destroyed = true

	if lobby._nakama then
		MPAPI.networking.nakama_lobby.forget()
	end

	MPAPI.chat.cleanup()

	lobby._pending_actions = {}

	if L.current == lobby then
		L.current = nil
	end

	-- A home lobby left while its group queue was forming or queued.
	local Group = MPAPI.matchmaking and MPAPI.matchmaking.group
	if Group and Group._on_lobby_gone then
		Group._on_lobby_gone(lobby)
	end

	if L.notify_lobby_gone then
		L.notify_lobby_gone(lobby)
	end
end
