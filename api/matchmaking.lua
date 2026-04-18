MPAPI.matchmaking = MPAPI.matchmaking or {}

-----------------------------
-- STATE
-----------------------------

local _handles = {}         -- list of active queue handles
local _subscribed = false   -- whether we have subscribed to the matchmaking topic

-----------------------------
-- HELPERS
-----------------------------

local function json_encode(tbl)
	if json and json.encode then
		return json.encode(tbl)
	end
	local j = require('json')
	return j.encode(tbl)
end

local function json_decode(str)
	if json and json.decode then
		return json.decode(str)
	end
	local j = require('json')
	return j.decode(str)
end

local function ensure_subscribed()
	if _subscribed then return end
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()
	if not conn or not mqtt then return end

	local topic = 'player/' .. conn.player_id .. '/matchmaking'

	mqtt:subscribe(topic, 1, function(payload_str)
		local ok, msg = pcall(json_decode, payload_str)
		if not ok or not msg then return end
		dispatch_matchmaking_message(msg)
	end)

	_subscribed = true
end

local function unsubscribe_if_empty()
	if #_handles > 0 then return end
	if not _subscribed then return end

	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()
	if not conn or not mqtt then
		_subscribed = false
		return
	end

	local topic = 'player/' .. conn.player_id .. '/matchmaking'
	mqtt:unsubscribe(topic)
	_subscribed = false
end

local function remove_handle(handle)
	for i, h in ipairs(_handles) do
		if h == handle then
			table.remove(_handles, i)
			break
		end
	end
	unsubscribe_if_empty()
end

local function find_handle_by_mode(mod_id, game_mode)
	for _, h in ipairs(_handles) do
		if h.mod_id == mod_id and h.game_mode == game_mode then
			return h
		end
	end
	return nil
end

local function find_handle_by_match_id(match_id)
	for _, h in ipairs(_handles) do
		if h.match_id == match_id then
			return h
		end
	end
	return nil
end

-- Forward declaration
dispatch_matchmaking_message = function(msg)
	local msg_type = msg.type

	if msg_type == 'match_found' then
		local handle = find_handle_by_mode(msg.modId, msg.gameMode)
		if handle then
			handle.match_id = msg.matchId
			-- Leave all other handles client-side (server already dequeued them)
			for _, h in ipairs(_handles) do
				if h ~= handle then
					h._left = true
					h:_fire('left', nil)
				end
			end
			-- Keep only this handle
			local matched = handle
			_handles = { matched }

			matched:_fire('match_found', msg)

			-- Auto-join the matchmade lobby
			local lobby = MPAPI.join_lobby(msg.modId, msg.lobbyCode)
			if lobby then
				lobby:on('connected', function()
					matched:_fire('lobby_ready', lobby)
				end)
			end
		end

	elseif msg_type == 'match_reconnect' then
		-- Reconnecting to an existing match
		local handle = find_handle_by_match_id(msg.matchId)
		if not handle then
			handle = MPAPI.matchmaking._make_handle(msg.modId, msg.gameMode)
			handle.match_id = msg.matchId
			handle._reconnected = true
		end

		local lobby = MPAPI.join_lobby(msg.modId, msg.lobbyCode)
		if lobby then
			local h = handle
			lobby:on('connected', function()
				h:_fire('lobby_ready', lobby)
			end)
		end

	elseif msg_type == 'match_resolved' then
		local handle = find_handle_by_match_id(msg.matchId)
		if handle then
			handle:_fire('match_resolved', msg.ratings)
			remove_handle(handle)
		end
	end
end

-----------------------------
-- HANDLE OBJECT
-----------------------------

MPAPI.matchmaking._make_handle = function(mod_id, game_mode)
	local handle = {
		mod_id = mod_id,
		game_mode = game_mode,
		match_id = nil,
		_left = false,
		_reconnected = false,
		_event_handlers = {},
	}

	function handle:on(event_name, handler)
		if not self._event_handlers[event_name] then
			self._event_handlers[event_name] = {}
		end
		local handlers = self._event_handlers[event_name]
		handlers[#handlers + 1] = handler
	end

	function handle:_fire(event_name, ...)
		local handlers = self._event_handlers[event_name]
		if not handlers then return end
		for _, handler in ipairs(handlers) do
			local ok, err = pcall(handler, ...)
			if not ok then
				MPAPI.sendWarnMessage('matchmaking handle event "' .. event_name .. '" error: ' .. tostring(err))
			end
		end
	end

	function handle:leave()
		if self._left then return end
		self._left = true
		remove_handle(self)

		local conn = MPAPI.get_connection()
		if not conn then return end

		conn.api:leave_matchmaking_queue(conn.jwt_token, {
			modId = self.mod_id,
			gameMode = self.game_mode,
		}, function(err)
			if err then
				MPAPI.sendWarnMessage('leave_matchmaking_queue error: ' .. tostring(err))
			end
		end)
	end

	function handle:report_result(placements, callback)
		if not self.match_id then
			if callback then callback('No active match', nil) end
			return
		end

		local conn = MPAPI.get_connection()
		if not conn then
			if callback then callback('Not connected', nil) end
			return
		end

		conn.api:report_match_result(conn.jwt_token, self.match_id, placements, callback)
	end

	return handle
end

-----------------------------
-- PUBLIC API
-----------------------------

-- Queue for a single mode. Returns a handle.
MPAPI.matchmaking.queue = function(opts)
	local conn = MPAPI.get_connection()
	if not conn or conn:get_state() ~= 'connected' then
		MPAPI.sendWarnMessage('matchmaking.queue: not connected')
		return nil
	end

	ensure_subscribed()

	local handle = MPAPI.matchmaking._make_handle(opts.mod_id, opts.game_mode)
	_handles[#_handles + 1] = handle

	conn.api:queue_matchmaking(conn.jwt_token, {
		modId = opts.mod_id,
		gameMode = opts.game_mode,
		minPlayers = opts.min_players,
		maxPlayers = opts.max_players,
	}, function(err, data)
		if err then
			remove_handle(handle)
			handle:_fire('error', err)
			return
		end
		handle:_fire('queued', data and data.position)
	end)

	return handle
end

-- Queue for multiple modes simultaneously. Returns array of handles.
MPAPI.matchmaking.queue_all = function(modes)
	local handles = {}
	for _, mode in ipairs(modes) do
		local h = MPAPI.matchmaking.queue(mode)
		if h then
			handles[#handles + 1] = h
		end
	end
	return handles
end

-- Leave all active queues.
MPAPI.matchmaking.leave_all = function()
	local conn = MPAPI.get_connection()
	if not conn then return end

	-- Clear local handles first
	local old = _handles
	_handles = {}
	_subscribed = false

	-- Mark all as left
	for _, h in ipairs(old) do
		h._left = true
	end

	-- Tell server to leave all queues
	conn.api:leave_all_matchmaking_queues(conn.jwt_token, function(err)
		if err then
			MPAPI.sendWarnMessage('leave_all_matchmaking_queues error: ' .. tostring(err))
		end
	end)

	-- Unsubscribe MQTT
	local mqtt = MPAPI.get_mqtt()
	if mqtt then
		local topic = 'player/' .. conn.player_id .. '/matchmaking'
		mqtt:unsubscribe(topic)
	end
end

-- Queue the entire private lobby as a group. Only callable by the lobby host.
MPAPI.matchmaking.queue_group = function(opts)
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		MPAPI.sendWarnMessage('matchmaking.queue_group: not in a lobby')
		return nil
	end

	-- queue() will detect the lobbyCode from the session server-side
	return MPAPI.matchmaking.queue(opts)
end

-- Fetch own rating for a given mode and season.
MPAPI.matchmaking.get_rating = function(mod_id, game_mode, season, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback('Not connected', nil)
		return
	end
	conn.api:get_matchmaking_rating(conn.jwt_token, mod_id, game_mode, season, callback)
end

-- Fetch leaderboard for a given mode and season.
MPAPI.matchmaking.get_leaderboard = function(mod_id, game_mode, season, opts, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback('Not connected', nil)
		return
	end
	opts = opts or {}
	conn.api:get_matchmaking_leaderboard(
		conn.jwt_token,
		mod_id,
		game_mode,
		season,
		opts.limit or 100,
		opts.offset or 0,
		callback
	)
end
