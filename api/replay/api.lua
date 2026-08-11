MPAPI.replay = MPAPI.replay or {}

-- Phase 6: download a stored run's replay. callback(err, data) where data is
-- {run={...}, logs=[{playerId, compressedEvents, carbonHash, eventCount, status}]}.
MPAPI.replay.get = function(run_id, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_replay(conn.jwt_token, run_id, callback)
end

-- §22.2 (+pagination): the player's own past run ids. opts = {page=,
-- page_size=} (both optional; server defaults to page 1, pageSize 20).
-- callback(err, data) where data is {runs = [{id, lobbyCode, modId,
-- lobbyType, status, startedAt, finalizedAt}, ...], total, page, pageSize}.
MPAPI.replay.list_mine = function(opts, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_my_runs(conn.jwt_token, opts, callback)
end

-- Crash-relaunch rejoin detection: does the player have a match still in
-- progress right now. callback(err, data) where data is
-- {active = {runId, lobbyCode, modId} | nil}.
MPAPI.replay.get_active_run = function(callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_active_run(conn.jwt_token, callback)
end

-- Phase 7: request a spectator token + one-time snapshot for a lobby.
-- callback(err, data) where data is {token, snapshot}.
MPAPI.replay.spectate_lobby = function(code, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:spectate_lobby(conn.jwt_token, code, callback)
end

-- §22.3: which live lobbies are currently spectatable. callback(err, data)
-- where data is {lobbies = [{code, modId, playerCount}, ...]}.
MPAPI.replay.list_spectatable = function(callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:list_spectatable(conn.jwt_token, callback)
end
