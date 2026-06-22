MPAPI.testing = {}

local _orig_get_current_lobby = MPAPI.get_current_lobby

-----------------------------
-- MOCK LOBBY
-----------------------------

function MPAPI.testing.mock_lobby(opts)
	opts = opts or {}
	local player_id = opts.player_id or 'test_player'
	local players = opts.players or { { id = player_id } }

	local lobby = {
		player_id = player_id,
		is_host = (opts.is_host == nil) and true or opts.is_host,
		code = 'TESTXX',
		mod_id = nil,
		_metadata = opts.metadata or {},
		_players = {},
		_gamemode_instance = opts.gamemode_instance or nil,
		_event_handlers = {},
		recorded_broadcasts = {},
	}

	for _, p in ipairs(players) do
		lobby._players[p.id] = { id = p.id, displayName = p.displayName }
	end

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
				MPAPI.sendWarnMessage('Mock lobby event "' .. event_name .. '" handler error: ' .. tostring(err))
			end
		end
	end

	function lobby:get_players()
		local result = {}
		for _, p in pairs(self._players) do
			result[#result + 1] = p
		end
		return result
	end

	function lobby:get_metadata()
		return self._metadata
	end

	function lobby:get_gamemode_instance()
		return self._gamemode_instance
	end

	function lobby:action(action_type)
		local broadcasts = self.recorded_broadcasts
		return {
			broadcast = function(_, params)
				broadcasts[#broadcasts + 1] = {
					action_key = action_type.key,
					params = params,
				}
			end,
		}
	end

	return lobby
end

-----------------------------
-- SET CURRENT LOBBY
-----------------------------

function MPAPI.testing.set_current_lobby(lobby)
	MPAPI.get_current_lobby = function()
		return lobby
	end
end

-----------------------------
-- MOCK MATCH HANDLE
-----------------------------

function MPAPI.testing.mock_match_handle(opts)
	opts = opts or {}

	local handle = {
		match_id = opts.match_id or nil,
		mod_id = nil,
		game_mode = nil,
		_left = false,
		leave_called = false,
		report_result_args = nil,
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
		if not handlers then
			return
		end
		for _, handler in ipairs(handlers) do
			local ok, err = pcall(handler, ...)
			if not ok then
				MPAPI.sendWarnMessage('Mock handle event "' .. event_name .. '" error: ' .. tostring(err))
			end
		end
	end

	function handle:leave()
		self.leave_called = true
		self._left = true
	end

	function handle:report_result(placements, callback)
		self.report_result_args = { placements = placements, callback = callback }
		if callback then
			callback(nil)
		end
	end

	return handle
end

-----------------------------
-- MOCK MATCHMAKING QUEUE
-----------------------------

function MPAPI.testing.mock_matchmaking_queue(handle)
	local original = MPAPI.matchmaking.queue
	MPAPI.testing._last_queue_opts = nil
	MPAPI.matchmaking.queue = function(opts)
		MPAPI.testing._last_queue_opts = opts
		return handle
	end
	return function()
		MPAPI.matchmaking.queue = original
	end
end

-----------------------------
-- LOCAL MESH
-----------------------------

-- Creates two in-process lobby objects wired together.
-- Broadcasting from either lobby calls action_type.on_receive on both,
-- with get_current_lobby returning the correct lobby for each call.
-- Use this for two-client tests without real MQTT.
function MPAPI.testing.create_local_mesh(opts)
	opts = opts or {}
	local p1 = opts.player1 or {}
	local p2 = opts.player2 or {}

	local shared_players = {
		{ id = p1.id or 'p1', displayName = p1.displayName },
		{ id = p2.id or 'p2', displayName = p2.displayName },
	}

	local lobby1 = MPAPI.testing.mock_lobby({
		player_id = p1.id or 'p1',
		is_host = (p1.is_host ~= false),
		players = shared_players,
		metadata = opts.metadata or {},
	})

	local lobby2 = MPAPI.testing.mock_lobby({
		player_id = p2.id or 'p2',
		is_host = p2.is_host or false,
		players = shared_players,
		metadata = opts.metadata or {},
	})

	local mesh = { lobby1 = lobby1, lobby2 = lobby2 }

	local function dispatch(source_lobby, action_type, params)
		source_lobby.recorded_broadcasts[#source_lobby.recorded_broadcasts + 1] = {
			action_key = action_type.key,
			params = params,
		}
		local saved = MPAPI.get_current_lobby
		for _, lobby in ipairs({ lobby1, lobby2 }) do
			MPAPI.get_current_lobby = function()
				return lobby
			end
			local ok, err = pcall(action_type.on_receive, action_type, source_lobby.player_id, params)
			if not ok then
				MPAPI.sendWarnMessage('mesh dispatch error for "' .. action_type.key .. '": ' .. tostring(err))
			end
		end
		MPAPI.get_current_lobby = saved
	end

	local function make_action_fn(source_lobby)
		return function(self, action_type)
			return {
				broadcast = function(_, params)
					dispatch(source_lobby, action_type, params)
				end,
			}
		end
	end

	lobby1.action = make_action_fn(lobby1)
	lobby2.action = make_action_fn(lobby2)

	return mesh
end

-----------------------------
-- RESET
-----------------------------

function MPAPI.testing.reset()
	MPAPI.get_current_lobby = _orig_get_current_lobby
	MPAPI.testing._last_queue_opts = nil
end
