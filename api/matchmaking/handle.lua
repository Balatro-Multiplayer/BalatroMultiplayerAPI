MPAPI.matchmaking = MPAPI.matchmaking or {}

-- A queue handle: the object returned to a mod when it joins matchmaking. It
-- carries the per-queue event listeners and its matchmaker ticket.
MPAPI.matchmaking._make_handle = function(mod_id, game_mode)
	local handle = {
		mod_id = mod_id,
		game_mode = game_mode,
		match_id = nil,
		_left = false,
		-- Set true once this handle's matched lobby has finished joining (LOBBY_READY fired)
		-- or the join attempt has failed (ERROR fired) -- see dispatch.lua's on_nakama_matched.
		-- Lets MPAPI.matchmaking.is_committed() (queue_timer.lua) distinguish "matched, still
		-- joining" from "already searching" and from "already in the match", since match_id
		-- alone is set for the whole match duration, not just the brief join window.
		_lobby_ready = false,
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
		-- Notify subscribers no matter which code path initiated the leave (a
		-- consumer mod's own cancel button, the queue-guard overlay, ...), and
		-- before the server round-trip so UI state resets even if it fails.
		self:_fire('left')

		if self._nakama_ticket then
			MPAPI.networking.nakama_lobby.unqueue(self._nakama_ticket)
		end
	end

	-- Kept for older callers: a matched game is refereed by its lobby
	-- (lobby:report_result), and the server stamps the run's start itself.
	function handle:report_result(placements, callback)
		if callback then callback(nil, nil) end
	end

	function handle:mark_started(callback)
		if callback then callback(nil, nil) end
	end

	return handle
end
