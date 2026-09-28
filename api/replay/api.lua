MPAPI.replay = MPAPI.replay or {}

-- With Nakama lobbies on, finished games are stored by the Nakama server
-- (BalatroMultiplayerServer nakama/src/lobby/storage.ts) rather than the API;
-- get/list_mine read them through its run RPCs and hand back the API's shapes,
-- so the replay browsers don't care where a run came from.
local function on_nakama()
	local L = MPAPI._internal.lobby
	return L ~= nil and L.nakama_enabled ~= nil and L.nakama_enabled()
end

local function nakama_rpc(id, body, callback)
	MPAPI.networking.nakama_lobby.rpc(id, body, function(err, data)
		if err then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)), nil)
			return
		end
		callback(nil, data)
	end)
end

-- Epoch ms -> the API's ISO timestamp.
local function iso_time(ms)
	if type(ms) ~= 'number' then
		return nil
	end
	return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(ms / 1000))
end

local function nakama_get(run_id, callback)
	nakama_rpc('run_get', { runId = run_id }, function(err, run)
		if err then
			callback(err, nil)
			return
		end
		nakama_rpc('run_logs', { runId = run_id }, function(logs_err, data)
			if logs_err then
				callback(logs_err, nil)
				return
			end
			local stored = (data and data.logs) or {}
			local logs = {}
			for _, player in ipairs(run.players or {}) do
				local log = stored[player.id]
				if log then
					logs[#logs + 1] = {
						playerId = player.id,
						events = log.events or {},
						carbonHash = log.carbonHash,
						eventCount = log.eventCount,
						status = log.truncated and 'partial' or 'complete',
						check = log.check,
					}
				end
			end
			callback(nil, {
				run = {
					id = run.runId,
					lobbyCode = run.code,
					modId = run.modId,
					status = run.status,
					seed = run.seed,
					stake = run.stake,
					startedAt = iso_time(run.startedAt),
					finalizedAt = iso_time(run.endedAt),
					placements = run.placements,
					players = run.players,
					logChecks = run.logChecks,
				},
				logs = logs,
			})
		end)
	end)
end

-- opts.cursor pages on from a previous call's data.cursor.
local function nakama_list_mine(opts, callback)
	nakama_rpc('runs_mine', { cursor = opts and opts.cursor }, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		local runs = {}
		for _, r in ipairs((data and data.runs) or {}) do
			runs[#runs + 1] = {
				id = r.runId,
				lobbyCode = r.code,
				modId = r.modId,
				status = r.status,
				place = r.place,
				startedAt = iso_time(r.startedAt),
				finalizedAt = iso_time(r.endedAt),
			}
		end
		local cursor = data and data.cursor
		callback(nil, {
			runs = runs,
			cursor = (cursor ~= nil and cursor ~= '') and cursor or nil,
			total = #runs,
			page = 1,
			pageSize = #runs,
		})
	end)
end

-- Phase 6: download a stored run's replay. callback(err, data) where data is
-- {run={...}, logs=[{playerId, compressedEvents, carbonHash, eventCount, status}]}.
-- A Nakama-stored run's logs carry decoded `events` instead of
-- compressedEvents, plus each log's `check` against its hash.
MPAPI.replay.get = function(run_id, callback)
	if on_nakama() then
		nakama_get(run_id, callback)
		return
	end
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
	if on_nakama() then
		nakama_list_mine(opts, callback)
		return
	end
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
