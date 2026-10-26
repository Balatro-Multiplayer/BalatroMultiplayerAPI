-- Lobbies hosted on Nakama: the create/join/rejoin entry points and the
-- mapping from the bmp_lobby match's ops onto the lobby object. The transport
-- is networking/nakama_lobby.lua.
--
-- The lobby itself (roster, player info, metadata, own state, host, kick,
-- leave, disconnect/rejoin) is server-authoritative.
-- Actions are relayed through the match, or run by the server when
-- authoritative (api/action/builtin.lua): ready, start, results and replay
-- capture, which the server stores with each finished game. Matchmaker groups
-- land in these lobbies too (api/matchmaking), and chat is a server RPC that
-- comes back as a CHAT op (BalatroMultiplayerServer nakama/src/chat).
-- Roster ids are Nakama user ids, and lobby.player_id is ours.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

local function NL()
	return MPAPI.networking.nakama_lobby
end

local function fail(lobby, message)
	lobby:_fire(MPAPI.LobbyEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(message)))
end

local function tear_down(lobby)
	if lobby._destroyed then
		return
	end
	L.cleanup(lobby)
	lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
	if MPAPI._internal.on_lobby_disconnected then
		MPAPI._internal.on_lobby_disconnected()
	end
end

-- The server refused to open `lobby` for us (creation switched off, no such
-- code, lobby full, ...): drop the half-made lobby and tell the player why.
-- Without this the refusal only reached the log and L.current kept pointing
-- at a lobby that never existed.
local function show_refusal(title_key, message)
	if MPAPI.show_notice then
		MPAPI.show_notice(title_key, tostring(message))
	end
end

local function refused(lobby, title_key, message)
	fail(lobby, message)
	tear_down(lobby)
	-- The seat may be in another mod's game, which this mod's UI can't show:
	-- offer it from MPAPI instead of a dead-end notice.
	if MPAPI._internal.is_seat_held_refusal(message) then
		MPAPI._internal.offer_held_seat(function(shown)
			if not shown then
				show_refusal(title_key, message)
			end
		end)
		return
	end
	show_refusal(title_key, message)
end

local function roster_from(players)
	local roster = {}
	for _, p in ipairs(players or {}) do
		if p.id then
			roster[p.id] = {
				id = p.id,
				displayName = p.displayName,
				preferredJoker = p.preferredJoker,
				mods = p.mods,
				-- MPAPI.Standing, worked out by the server; nil for a seat
				-- taken before standings existed.
				standing = p.standing,
				is_away = p.isAway or false,
			}
		end
	end
	return roster
end

-- Sets the lobby to the snapshot's state (sent on every join, including a
-- rejoin after a socket drop). On a rejoin, fires the events for whatever
-- changed while this client was away.
L.apply_snapshot = function(lobby, snapshot, announce)
	if lobby._destroyed or type(snapshot) ~= 'table' then
		return
	end
	local before = lobby._players
	local was_host = lobby.is_host
	local roster = roster_from(snapshot.players)

	NL().set_grace_seconds(snapshot.graceSeconds)
	lobby.code = snapshot.code or lobby.code
	lobby.max_players = snapshot.maxPlayers or lobby.max_players
	lobby.type = snapshot.type or 'private'
	lobby.host_id = snapshot.hostId
	lobby.is_host = snapshot.hostId == lobby.player_id
	lobby._metadata = type(snapshot.metadata) == 'table' and snapshot.metadata or {}
	lobby._player_state = snapshot.ownState
	lobby._players = roster
	-- The group casual queue this (home) lobby is in, or nil; a matchmade
	-- lobby's team plan ({ {ids}, {ids} } for a Teams match with groups).
	local had_group = lobby.group_queue
	lobby.group_queue = type(snapshot.groupQueue) == 'table' and snapshot.groupQueue or nil
	lobby.team_plan = type(snapshot.teamPlan) == 'table' and snapshot.teamPlan or nil

	local game = type(snapshot.game) == 'table' and snapshot.game or {}
	local was_started = lobby._game.started ~= nil
	lobby._game.ready = {}
	for id, ready in pairs(type(game.ready) == 'table' and game.ready or {}) do
		if ready == true and roster[id] then
			lobby._game.ready[id] = true
			MPAPI.set_player_ready(lobby, id, true)
		end
	end
	lobby._game.reported = {}
	for _, id in ipairs(type(game.reported) == 'table' and game.reported or {}) do
		lobby._game.reported[id] = true
	end
	if type(game.started) == 'table' then
		if announce and not was_started then
			L.apply_game_started(lobby, game.started)
		else
			lobby._game.started = {
				run_id = game.started.runId,
				seed = game.started.seed,
				stake = game.started.stake,
				options = game.started.options,
				players = game.started.players,
			}
		end
	elseif was_started and announce then
		-- It ended while we were away; the result went out without us.
		L.apply_game_ended(lobby, { status = 'unknown', placements = {} })
	else
		lobby._game.started = nil
	end

	if had_group or lobby.group_queue then
		lobby:_fire(MPAPI.LobbyEvent.GROUP_QUEUE, lobby.group_queue)
	end
	local Group = MPAPI.matchmaking and MPAPI.matchmaking.group
	if Group and Group._on_view then
		Group._on_view(lobby, lobby.group_queue)
	end

	if not announce then
		return
	end
	for id in pairs(before) do
		if not roster[id] then
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_LEFT, id)
		end
	end
	for id, player in pairs(roster) do
		if not before[id] then
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_JOINED, id)
			lobby:_fire(MPAPI.LobbyEvent.PLAYER_INFO, id, player)
		end
	end
	if lobby.is_host ~= was_host then
		lobby:_fire(MPAPI.LobbyEvent.HOST_CHANGED, snapshot.hostId)
	end
	-- A rejoin after a socket drop missed the draft's state broadcasts: catch up
	-- from the host's metadata mirror.
	if MPAPI.BanPick and MPAPI.BanPick.sync_from_metadata then
		MPAPI.BanPick.sync_from_metadata(lobby)
	end
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

local function on_data(lobby, on_ready, op, data)
	if lobby._destroyed then
		return
	end
	local ServerOp = NL().ServerOp
	if op == ServerOp.SNAPSHOT then
		local first = not lobby._nakama_ready
		L.apply_snapshot(lobby, data, not first)
		if first then
			lobby._nakama_ready = true
			on_ready(lobby)
		end
	elseif op == ServerOp.EVENT then
		L.apply_event(lobby, data)
	elseif op == ServerOp.METADATA then
		L.apply_metadata(lobby, data)
	elseif op == ServerOp.PLAYER_INFO then
		if type(data.playerId) == 'string' then
			L.apply_player_info(lobby, data.playerId, type(data.info) == 'table' and data.info or nil)
		end
	elseif op == ServerOp.ACTION then
		L.deliver_action(lobby, {
			cid = data.cid,
			action = data.action,
			from = data.from,
			to = data.to,
			params = data.params,
			response_to = data.responseTo,
		})
	elseif op == ServerOp.ACTION_REJECTED then
		L.reject_action(lobby, data)
	elseif op == ServerOp.CHAT then
		if type(data.senderId) == 'string' then
			MPAPI.chat.on_message(lobby, data.senderId, data.displayName, data.message)
		end
	elseif op == ServerOp.ERROR then
		fail(lobby, data.message or 'Lobby error')
	elseif op == ServerOp.SERVER_RESTARTING then
		-- The socket drops next; the rejoin finds the lobby again once the
		-- server is back.
		MPAPI.sendWarnMessage('[nakama_lobby] server restarting; rejoining ' .. tostring(lobby.code) .. ' when it is back')
		lobby._server_restarting = true
		lobby:_fire(MPAPI.LobbyEvent.SERVER_RESTARTING, { grace_seconds = data.graceSeconds })
	elseif op == ServerOp.GROUP_QUEUE then
		-- The group casual queue moved on (forming / queued / away, or idle:
		-- over, with its reason).
		if type(data) == 'table' then
			lobby.group_queue = data.phase ~= 'idle' and data or nil
			lobby:_fire(MPAPI.LobbyEvent.GROUP_QUEUE, lobby.group_queue, data)
			local Group = MPAPI.matchmaking and MPAPI.matchmaking.group
			if Group and Group._on_view then
				Group._on_view(lobby, data)
			end
		end
	elseif op == ServerOp.REPLAY_TAIL then
		if type(data.tails) == 'table' then
			lobby:_fire(MPAPI.LobbyEvent.REPLAY_TAIL, data.tails)
		end
	end
end

local function connected(lobby)
	lobby:_fire(MPAPI.LobbyEvent.CONNECTED)
	MPAPI.chat.init(lobby)
	if MPAPI._internal.on_lobby_connected then
		MPAPI._internal.on_lobby_connected(lobby)
	end
end

-- Joins the lobby's match; on_ready(lobby) runs on the first snapshot.
local function attach(lobby, match_id, on_ready)
	local session = MPAPI.get_nakama_session()
	lobby.player_id = session and session.user_id or lobby.player_id
	NL().join(match_id, lobby.mod_id, {
		data = function(op, data)
			on_data(lobby, on_ready, op, data)
		end,
		dropped = function()
			MPAPI.sendDebugMessage('[nakama_lobby] socket dropped, rejoining ' .. tostring(lobby.code))
		end,
		rejoined = function()
			lobby._server_restarting = nil
			MPAPI.sendDebugMessage('[nakama_lobby] rejoined ' .. tostring(lobby.code))
		end,
		lost = function(reason, gave_up)
			MPAPI.sendWarnMessage('[nakama_lobby] lost lobby ' .. tostring(lobby.code) .. ': ' .. tostring(reason))
			tear_down(lobby)
			-- A reconnect after a socket drop can be refused for standing too
			-- (the allowlist changed while the connection was down). The seat
			-- is kept as for the first join's refusal, so offer the same
			-- Retry/Leave; without it the player sat in a run whose lobby was
			-- gone, with nothing on screen.
			if MPAPI.is_forfeited_refusal(reason) and MPAPI.show_forfeited_notice then
				MPAPI.show_forfeited_notice()
				return
			end
			-- Reconnecting ran out of time: the server forfeited the seat.
			if gave_up and MPAPI.show_connection_lost_notice then
				MPAPI.show_connection_lost_notice()
				return
			end
			local rejoin_refusal = MPAPI.standing.parse_rejoin_refusal(reason)
			if rejoin_refusal and MPAPI.show_rejoin_refused then
				MPAPI.show_rejoin_refused(rejoin_refusal)
			end
		end,
	}, function(err)
		if not err or lobby._destroyed then
			return
		end
		-- The grace period forfeited our seat: the match is over for us.
		if MPAPI.is_forfeited_refusal(err) and MPAPI.show_forfeited_notice then
			fail(lobby, err)
			tear_down(lobby)
			MPAPI.show_forfeited_notice()
			return
		end
		-- A matchmade game refuses an account below its standing but keeps the
		-- seat: offer Retry (after fixing the mods) or forfeiting it.
		local rejoin_refusal = MPAPI.standing.parse_rejoin_refusal(err)
		if rejoin_refusal and MPAPI.show_rejoin_refused then
			fail(lobby, err)
			tear_down(lobby)
			MPAPI.show_rejoin_refused(rejoin_refusal)
			return
		end
		refused(lobby, 'k_lobby_join_failed_title', err)
	end)
end

local function new_lobby(conn, mod_id, opts)
	local lobby = L.create_object({
		mod_id = mod_id,
		player_id = nil,
		connection = conn,
		is_host = opts.is_host,
		max_players = opts.max_players,
		type = opts.type,
		nakama = true,
	})
	L.current = lobby
	return lobby
end

local function connected_conn(what)
	local conn = MPAPI.get_connection()
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		MPAPI.sendWarnMessage(what .. ': not connected')
		if MPAPI.show_notice then
			MPAPI.show_notice('k_status_offline', localize('k_lobby_not_connected'))
		end
		return nil
	end
	return conn
end

L.nakama_create_lobby = function(mod_id, opts)
	local conn = connected_conn('create_lobby')
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, mod_id, { is_host = true, max_players = opts.max_players })
	NL().create(mod_id, opts.max_players, function(err, data)
		if lobby._destroyed then
			return
		end
		if err then
			refused(lobby, 'k_lobby_create_failed_title', err)
			return
		end
		lobby.code = data.code
		attach(lobby, data.matchId, connected)
	end)
	return lobby
end

L.nakama_join_lobby = function(mod_id, code)
	local conn = connected_conn('join_lobby')
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, mod_id, {})
	NL().find(code, mod_id, function(err, data)
		if lobby._destroyed then
			return
		end
		if err then
			refused(lobby, 'k_lobby_join_failed_title', err)
			return
		end
		lobby.code = data.code
		attach(lobby, data.matchId, connected)
	end)
	return lobby
end

-- Joins the lobby the matchmaker made (no code lookup: the ticket's match id is
-- all there is; the code arrives with the first snapshot).
L.nakama_join_match = function(mod_id, match_id)
	local conn = connected_conn('join_match')
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, mod_id, {})
	attach(lobby, match_id, connected)
	return lobby
end

-- Rejoins the lobby lobby_current reported after a game restart
-- (lobby_data = the reconnected_lobby context, see networking/connection.lua).
-- on_ready(lobby) runs once the snapshot is in, after CONNECTED.
L.nakama_rejoin_lobby = function(lobby_data, on_ready)
	local conn = MPAPI.get_connection()
	if not conn then
		return
	end
	local lobby = new_lobby(conn, lobby_data.modId, { type = lobby_data.type })
	lobby.code = lobby_data.code
	attach(lobby, lobby_data.matchId, function(l)
		connected(l)
		if on_ready then
			on_ready(l)
		end
	end)
end

L.nakama_leave_current = function(cb)
	NL().leave_current(cb or function() end)
end

-- Checks for a lobby seat left over from before a restart; cb(lobby_data) or
-- cb(nil). lobby_data is the reconnected_lobby context the prompt reads.
L.nakama_check_current = function(cb)
	NL().current(function(err, data)
		if err or not data then
			cb(nil)
			return
		end
		cb({ nakama = true, matchId = data.matchId, code = data.code, modId = data.modId, type = MPAPI.LobbyType.PRIVATE })
	end)
end
