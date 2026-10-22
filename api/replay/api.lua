MPAPI.replay = MPAPI.replay or {}

-- Finished games are stored by the Nakama server (BalatroMultiplayerServer
-- nakama/src/lobby/storage.ts); get/list_mine read them through its run RPCs.

local function nakama_rpc(id, body, callback)
	MPAPI.networking.nakama_lobby.rpc(id, body, function(err, data)
		if err then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)), nil)
			return
		end
		callback(nil, data)
	end)
end

-- Epoch ms -> an ISO timestamp.
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
-- {run={...}, logs=[{playerId, events, carbonHash, eventCount, status, check}]},
-- `check` being the server's verdict on the log against its hash.
MPAPI.replay.get = function(run_id, callback)
	nakama_get(run_id, callback)
end

-- §22.2 (+pagination): the player's own past run ids. opts = {page=,
-- page_size=} (both optional; server defaults to page 1, pageSize 20).
-- callback(err, data) where data is {runs = [{id, lobbyCode, modId,
-- lobbyType, status, startedAt, finalizedAt}, ...], total, page, pageSize}.
MPAPI.replay.list_mine = function(opts, callback)
	nakama_list_mine(opts, callback)
end

-- How many server pages with none of the mod's runs list_mine_of reads past
-- before showing what it has.
MPAPI.replay.MOD_PAGE_SKIP_LIMIT = 5

-- Server pages hold every mod's runs (runs_mine has no modId filter), so a
-- mod's browser filtering only the first page misses its own runs behind
-- another mod's newer ones. Reads on past pages holding none of `mod_id`'s
-- runs. callback(err, data): data = {runs, cursor} like list_mine, runs only
-- `mod_id`'s; data.cursor (nil at the end) continues after them.
MPAPI.replay.list_mine_of = function(mod_id, opts, callback)
	local function read(cursor, skipped)
		nakama_list_mine({ cursor = cursor }, function(err, data)
			if err then
				callback(err, nil)
				return
			end
			local runs = {}
			for _, run in ipairs(data.runs) do
				if run.modId == mod_id then
					runs[#runs + 1] = run
				end
			end
			if #runs == 0 and data.cursor and skipped < MPAPI.replay.MOD_PAGE_SKIP_LIMIT then
				read(data.cursor, skipped + 1)
				return
			end
			callback(nil, { runs = runs, cursor = data.cursor })
		end)
	end
	read(opts and opts.cursor or nil, 0)
end

-- Crash-relaunch rejoin detection: does the player have a match still in
-- progress right now. callback(err, data) where data is
-- {active = {runId, lobbyCode, modId} | nil}.
MPAPI.replay.get_active_run = function(callback)
	nakama_rpc('run_active', {}, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		local active = data and data.active
		callback(nil, {
			active = active and {
				runId = active.runId,
				lobbyCode = active.code,
				modId = active.modId,
				events = active.events or {},
				-- What the game takes back (MPAPI.Standing 'valid' or
				-- 'verified'); nil for a private lobby, which never gates.
				requiredStanding = type(active.requiredStanding) == 'string' and active.requiredStanding or nil,
			} or nil,
			-- The caller's StandingView now, to compare against it.
			standing = data and data.standing or nil,
		})
	end)
end

-- Watches the lobby as a spectator match (the server's
-- lobby/spectate.ts). callback(err, data) once the snapshot is in, data being
-- {snapshot, players, runId, code}; then handlers.event({t,
-- player_id, opcode, args}) for each participant replay event, and
-- handlers.ended(reason) once watching stops (lobby closed, connection lost).
local function nakama_spectate(code, mod_id, callback, handlers)
	handlers = handlers or {}
	local NL = MPAPI.networking.nakama_lobby
	local answered = false
	local function answer(err, data)
		if answered then
			return
		end
		answered = true
		callback(err and MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(err)) or nil, data)
	end
	local function ended(reason)
		if not answered then
			answer(reason, nil)
		elseif handlers.ended then
			handlers.ended(reason)
		end
	end
	NL.find(code, mod_id, function(err, found)
		if err or not found or not found.matchId then
			answer(err or 'Lobby not found', nil)
			return
		end
		NL.spectate(found.matchId, mod_id, {
			data = function(op, data)
				if op == NL.ServerOp.SPECTATE_SNAPSHOT then
					answer(nil, {
						snapshot = data.snapshot or {},
						players = data.players or {},
						runId = data.runId,
						code = data.code,
					})
				elseif op == NL.ServerOp.SPECTATE_EVENT then
					if handlers.event then
						handlers.event({ t = data.t, player_id = data.playerId, opcode = data.opcode, args = data.args })
					end
				elseif op == NL.ServerOp.EVENT and data.type == 'lobby_closed' then
					NL.unspectate()
					ended('Lobby closed')
				end
			end,
			lost = ended,
		}, function(join_err)
			if join_err then
				answer(join_err, nil)
			end
		end)
	end)
end

-- Watches a lobby: callback(err, data) once the snapshot is in, then the live
-- feed through `handlers` (see nakama_spectate). mod_id is the watching mod;
-- the server refuses a lobby of another mod.
MPAPI.replay.spectate_lobby = function(code, callback, handlers, mod_id)
	nakama_spectate(code, mod_id, callback, handlers)
end

-- Stops watching a lobby.
MPAPI.replay.stop_spectating = function()
	MPAPI.networking.nakama_lobby.unspectate()
end

-- §22.3: which live lobbies are currently spectatable. callback(err, data)
-- where data is {lobbies = [{code, modId, playerCount}, ...]}.
MPAPI.replay.list_spectatable = function(callback)
	nakama_rpc('spectate_list', {}, callback)
end
