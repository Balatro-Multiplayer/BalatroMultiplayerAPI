MPAPI.matchmaking = MPAPI.matchmaking or {}

-- A queue handle: the object returned to a mod when it joins matchmaking. It
-- carries the per-queue event listeners and the server round-trips (leave, report
-- result, mark run start) scoped to its match.
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
		if not handlers then
			return
		end
		for _, handler in ipairs(handlers) do
			local ok, err = pcall(handler, ...)
			if not ok then
				MPAPI.sendWarnMessage('matchmaking handle event "' .. event_name .. '" error: ' .. tostring(err))
			end
		end
	end

	function handle:leave()
		if self._left then
			return
		end
		self._left = true
		MPAPI._internal.mm.remove_handle(self)

		local conn = MPAPI.get_connection()
		if not conn then
			return
		end

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
			if callback then callback(MPAPI.make_error(MPAPI.ErrorKind.NO_ACTIVE_MATCH, 'No active match'), nil) end
			return
		end

		local conn = MPAPI.get_connection()
		if not conn then
			if callback then callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil) end
			return
		end

		conn.api:report_match_result(conn.jwt_token, self.match_id, placements, callback)
	end

	-- Signal that the run has started (host only). The server stamps the start time once,
	-- forming the basis for server-measured timing leaderboards (e.g. fastest completion).
	function handle:mark_started(callback)
		if not self.match_id then
			if callback then callback(MPAPI.make_error(MPAPI.ErrorKind.NO_ACTIVE_MATCH, 'No active match'), nil) end
			return
		end

		local conn = MPAPI.get_connection()
		if not conn then
			if callback then callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil) end
			return
		end

		conn.api:mark_run_start(conn.jwt_token, self.match_id, callback)
	end

	return handle
end
