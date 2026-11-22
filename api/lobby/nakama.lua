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

-- The mod that owns a lobby may keep a game view on the server. The API only carries it: what an
-- input or a view holds, how inputs are numbered and resent, and where the view is kept are the mod's.
local view_handlers = {}

-- fn(lobby, view) gets every view the server sends for that mod's lobbies. One per mod.
function MPAPI.on_match_view(mod_id, fn)
	view_handlers[mod_id] = fn
end

-- Sends one input (a table) from the mod that owns the lobby. False when it did not leave (the
-- socket is down), so the mod can send it again.
function MPAPI.send_match_input(lobby, input)
	if lobby._destroyed or type(input) ~= 'table' then
		return false
	end
	return NL().send(NL().ClientOp.INPUT, input)
end

function L.deliver_match_view(lobby, view)
	local handler = view_handlers[lobby.mod_id]
	if not handler or type(view) ~= 'table' then
		return
	end
	local ok, err = pcall(handler, lobby, view)
	if not ok then
		MPAPI.sendWarnMessage('[nakama_lobby] view handler of ' .. tostring(lobby.mod_id) .. ' failed: ' .. tostring(err))
	end
end

local function tear_down(lobby)
	if lobby._destroyed then
		return
	end
	L.cleanup(lobby)
	lobby:_fire(MPAPI.LobbyEvent.DISCONNECTED)
	if MPAPI._internal.on_lobby_disconnected then
		MPAPI._internal.on_lobby_disconnected(lobby)
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

-- Where an away player's forfeit falls on this client's clock (love.timer.getTime), or nil while
-- they are present or the server named no time. Placed by the server time sent beside it, from
-- `received_local` (when the message arrived on this clock; now if omitted).
function L.forfeit_local(forfeits_at, server_now, received_local)
	if type(forfeits_at) ~= 'number' or type(server_now) ~= 'number' then
		return nil
	end
	return (received_local or love.timer.getTime()) + (forfeits_at - server_now) / 1000
end

local function roster_from(players, server_now)
	local roster = {}
	for _, p in ipairs(players or {}) do
		if p.id then
			roster[p.id] = {
				id = p.id,
				displayName = MPAPI.plain_letters(p.displayName),
				preferredJoker = p.preferredJoker,
				mods = p.mods,
				-- MPAPI.Standing, worked out by the server; nil for a seat
				-- taken before standings existed.
				standing = p.standing,
				is_away = p.isAway or false,
				forfeits_at_local = L.forfeit_local(p.forfeitsAt, server_now),
				catching_up = p.catchingUp == true,
			}
		end
	end
	return roster
end

-- Where the server's race start falls on this client's clock (love.timer.getTime), or nil while
-- the race has not started. Worked out from the snapshot's own server time, so the client's clock
-- and the server's need not agree; the delay of the snapshot itself is the only error.
local function race_started_local(started, server_now)
	if type(started.raceStartedAt) ~= 'number' or type(server_now) ~= 'number' then
		return nil
	end
	return love.timer.getTime() - (server_now - started.raceStartedAt) / 1000
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
	local roster = roster_from(snapshot.players, snapshot.serverNow)

	NL().set_grace_seconds(snapshot.graceSeconds)
	lobby.code = snapshot.code or lobby.code
	lobby.max_players = snapshot.maxPlayers or lobby.max_players
	lobby.type = snapshot.type or 'private'
	lobby.host_id = snapshot.hostId
	lobby.is_host = snapshot.hostId == lobby.player_id
	-- Server-advertised protocol versions, not host-editable metadata.
	-- Missing on older servers: consumers must treat that as unsupported.
	lobby.server_features = type(snapshot.serverFeatures) == 'table' and snapshot.serverFeatures or {}
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
	local ready_list = type(game.ready) == 'table' and game.ready or {}
	-- On a rejoin the ready events wait for the roster events below: a listener looks the player up.
	if not announce then
		L.apply_ready_list(lobby, ready_list, before)
	end
	lobby._game.result_pending = game.resultPending == true
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
		if lobby._game.started then
			lobby._game.started.race_started_local = race_started_local(game.started, snapshot.serverNow)
		end
	elseif was_started and announce then
		-- It ended while we were away; the result went out without us.
		L.apply_game_ended(lobby, { status = 'unknown', placements = {} })
	else
		lobby._game.started = nil
	end

	L.adopt_log_seq(lobby, game.logSeq)

	L.apply_setup(lobby, type(game.setup) == 'table' and game.setup or { results = {} }, not announce)

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
	-- A player who dropped or came back while we were away.
	for id, player in pairs(roster) do
		local old = before[id]
		if old and old.is_away ~= player.is_away then
			if player.is_away then
				lobby:_fire(MPAPI.LobbyEvent.PLAYER_DISCONNECTED, id, player.forfeits_at_local)
			else
				lobby:_fire(MPAPI.LobbyEvent.PLAYER_RECONNECTED, id)
			end
		end
	end
	L.apply_ready_list(lobby, ready_list, before)
	if lobby.is_host ~= was_host then
		lobby:_fire(MPAPI.LobbyEvent.HOST_CHANGED, snapshot.hostId)
	end
	-- Listeners that keep their own state from broadcasts catch up from the snapshot here: a
	-- rejoin after a socket drop missed those broadcasts. (Setup state is already applied above.)
	lobby:_fire(MPAPI.LobbyEvent.SNAPSHOT_APPLIED, snapshot)
	lobby:_fire(MPAPI.LobbyEvent.METADATA_CHANGED, lobby._metadata)
end

-- A lobby joined behind the player's back (a crash rejoin, while the run is
-- rebuilt from the player's own log) takes the snapshot, then holds every
-- other message. The game is not in that lobby yet, so a held action must not
-- reach its mod, and a held event must not fire before the mod listens. They
-- play in order when the lobby is attached (L.attach_detached). An event that
-- ends this client's seat (a forfeit, a closed lobby) is
-- not held: the lobby is dropped at once, which aborts the catch-up.
local function hold(lobby, op, data)
	if not (lobby._holding and lobby._nakama_ready) then
		return false
	end
	if op == NL().ServerOp.EVENT and L.ends_own_seat(lobby, data) then
		return false
	end
	-- A held event's server times are placed from its arrival, not from its replay.
	if type(data) == 'table' and op == NL().ServerOp.EVENT then
		data.received_local = love.timer.getTime()
	end
	lobby._held_messages[#lobby._held_messages + 1] = { op = op, data = data }
	return true
end

-- Whether this client's connection to the lobby's match is up (lobby._connection_state). A drop sets
-- DROPPED; the seat coming back, by a rejoin or a reattach, ends it.
local CONNECTION = { UP = 'up', DROPPED = 'dropped' }

-- The seat is gone from the socket or the held match: tells listeners once per drop.
local function seat_lost(lobby)
	if lobby._connection_state == CONNECTION.DROPPED then return end
	lobby._connection_state = CONNECTION.DROPPED
	lobby:_fire(MPAPI.LobbyEvent.CONNECTION_DROPPED)
end

-- The seat is back after a rejoin (a socket drop's, or a reattach after a teardown): the replay
-- events kept while away go out again, and the server, which starts a new session as "not
-- catching up", hears the flag again. Runs from the rejoin snapshot and from the transport's
-- rejoined notice, whichever the socket counts first; CONNECTION_RESTORED fires on the first.
local function seat_back(lobby)
	lobby._server_restarting = nil
	if lobby._connection_state == CONNECTION.DROPPED then
		lobby._connection_state = CONNECTION.UP
		lobby:_fire(MPAPI.LobbyEvent.CONNECTION_RESTORED)
	end
	L.resend_log_events(lobby)
	if lobby._catching_up then
		lobby:set_catching_up(true)
	end
end

local function on_data(lobby, on_ready, op, data)
	if lobby._destroyed then
		return
	end
	if hold(lobby, op, data) then
		return
	end
	local ServerOp = NL().ServerOp
	if op == ServerOp.SNAPSHOT then
		local first = not lobby._nakama_ready
		L.apply_snapshot(lobby, data, not first)
		if first then
			lobby._nakama_ready = true
			on_ready(lobby)
		else
			seat_back(lobby)
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
	elseif op == ServerOp.VIEW then
		L.deliver_match_view(lobby, data)
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

-- The server's answer to a join of a match it no longer has: the error text of Nakama's
-- match join (Nakama's own English string; the SDK gives no status code for it).
local function is_match_gone(reason)
	return type(reason) == 'string' and reason:find('Match not found', 1, true) ~= nil
end

-- How an attach came about, kept on the lobby (_join_kind) and set on every attach. A refused
-- reattach follows the seat to a new match once; one that followed to a new match is final.
local JOIN_KIND = { FIRST = 'first', REATTACH = 'reattach', REATTACH_NEW_MATCH = 'reattach new match' }

-- Joins the lobby's match; on_ready(lobby) runs on the first snapshot.
local function attach(lobby, match_id, on_ready, save_to_load, join_kind)
	local session = MPAPI.get_nakama_session()
	lobby.player_id = session and session.user_id or lobby.player_id
	lobby._match_id = match_id
	lobby._join_kind = join_kind or JOIN_KIND.FIRST
	lobby._connection_state = lobby._connection_state or CONNECTION.UP
	NL().join(match_id, lobby.mod_id, {
		data = function(op, data)
			on_data(lobby, on_ready, op, data)
		end,
		dropped = function()
			MPAPI.match_log('debug', '[nakama_lobby] socket dropped, rejoining ' .. tostring(lobby.code))
			seat_lost(lobby)
		end,
		-- A rejoin refused only because the launcher verdict lapsed while the
		-- socket was down (it lasts 6 minutes and is renewed over the socket):
		-- verify again and retry, once per drop, instead of losing the lobby
		-- and replaying the run.
		refused_wait = function(err, retry)
			local refusal = MPAPI.standing.parse_rejoin_refusal(err)
			if not refusal or refusal.code ~= MPAPI.RejoinRefusalCode.VERIFICATION_PENDING or lobby._reverified then
				return false
			end
			lobby._reverified = true
			MPAPI.match_log('debug', '[nakama_lobby] rejoin waits for a launcher verdict ' .. tostring(lobby.code))
			MPAPI.rejoin_recheck.run(function(outcome)
				-- A failed verdict is final: asking again gets the same refusal.
				retry(outcome == MPAPI.VerdictOutcome.FAILED)
			end)
			return true
		end,
		rejoined = function()
			lobby._reverified = nil
			-- Usually a no-op: the rejoin snapshot already did it. This catches the
			-- case where that snapshot came before the socket counted as up.
			seat_back(lobby)
			MPAPI.match_log('debug', '[nakama_lobby] rejoined ' .. tostring(lobby.code))
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
			-- The server came back without the match while a run was on screen.
			if is_match_gone(reason) and G and G.STAGE == G.STAGES.RUN and MPAPI.show_connection_lost_notice then
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
		-- A reattach names the match the lobby had; a server restart may have brought
		-- the lobby back under a new one. Follow the seat once before giving up.
		if lobby._join_kind == JOIN_KIND.REATTACH then
			L.nakama_check_current(function(current)
				if lobby._destroyed then
					return
				end
				if current and current.matchId and current.matchId ~= match_id then
					attach(lobby, current.matchId, on_ready, save_to_load, JOIN_KIND.REATTACH_NEW_MATCH)
				else
					refused(lobby, 'k_lobby_join_failed_title', err)
				end
			end)
			return
		end
		refused(lobby, 'k_lobby_join_failed_title', err)
	end, save_to_load)
end

-- Every Nakama lobby object, so a connection teardown reaches the detached and half-joined ones too.
local live_lobbies = setmetatable({}, { __mode = 'k' })

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
	live_lobbies[lobby] = true
	-- A detached lobby is not the one the game is in (L.current) until it is
	-- attached; it holds what the server sends meanwhile.
	if opts.detached then
		lobby._holding = true
		lobby._held_messages = {}
	else
		L.current = lobby
	end
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

-- Takes the seat back in the match `lobby` was attached to, after a connection
-- teardown let go of the match while the lobby object stayed. The lobby already
-- had its first snapshot, so the join's snapshot is handled as a rejoin: the
-- roster catches up, the view is read and unconfirmed log events go out again.
-- False when the lobby is not one to rejoin.
L.nakama_reattach = function(lobby)
	if not (lobby._nakama and lobby._match_id and lobby._nakama_ready) or lobby._destroyed or NL().in_match() then
		return false
	end
	attach(lobby, lobby._match_id, function() end, nil, JOIN_KIND.REATTACH)
	return true
end

-- A connection teardown (networking/connection.lua) is letting go of the held match. The current
-- lobby with its seat is DROPPED until a reattach ends it, as for a socket drop. A lobby with no
-- seat to come back to (its first join in flight, or detached for a crash rejoin) is lost.
L.nakama_match_released = function()
	local lobbies = {}
	for lobby in pairs(live_lobbies) do
		lobbies[#lobbies + 1] = lobby
	end
	for _, lobby in ipairs(lobbies) do
		if not lobby._destroyed and lobby._match_id then
			if lobby == L.current and lobby._nakama_ready then
				seat_lost(lobby)
			else
				tear_down(lobby)
			end
		end
	end
end

-- The login after a teardown failed, so no reattach is coming: a lobby still DROPPED is lost
-- (DISCONNECTED), which is how a drop always ends in RESTORED or DISCONNECTED.
L.nakama_connection_failed = function()
	local lobby = L.current
	if lobby and lobby._nakama and lobby._connection_state == CONNECTION.DROPPED and not NL().in_match() then
		tear_down(lobby)
	end
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

-- Takes the seat in the lobby the server kept (lobby_data, as for
-- nakama_rejoin_lobby) without making it the current lobby: the player's own
-- run is rebuilt from their log first (api/playback/rejoin.lua). on_ready(lobby)
-- runs on the first snapshot, so a refused seat (a forfeit, a closed lobby)
-- is known before anything is rebuilt. Messages after that are held until
-- L.attach_detached.
L.nakama_rejoin_detached = function(lobby_data, on_ready, save_to_load)
	local conn = MPAPI.get_connection()
	if not conn then
		return nil
	end
	local lobby = new_lobby(conn, lobby_data.modId, { type = lobby_data.type, detached = true })
	lobby.code = lobby_data.code
	attach(lobby, lobby_data.matchId, on_ready, save_to_load)
	return lobby
end

-- Makes a detached lobby the current one: CONNECTED fires (the mod's lobby
-- handlers must be on it already), then the messages it held play in order.
L.attach_detached = function(lobby)
	if lobby._destroyed or not lobby._holding then
		return
	end
	L.current = lobby
	connected(lobby)
	lobby._holding = false
	local held = lobby._held_messages
	lobby._held_messages = {}
	for _, message in ipairs(held) do
		if lobby._destroyed then
			return
		end
		on_data(lobby, nil, message.op, message.data)
	end
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
