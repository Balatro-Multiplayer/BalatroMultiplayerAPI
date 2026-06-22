-----------------------------
-- Lobby start-flow primitives
-----------------------------
-- Reusable building blocks for lobby "everyone get ready, then start" flows and
-- unanimous votes. The mod owns its own ready / vote action types and broadcasting;
-- these helpers just tally roster state against the current lobby.

-- Tracks per-player "ready" state for a start flow. The host records each client's
-- ready (its own typically arrives via the action broadcast loopback); all_ready()
-- reports once every player currently in the lobby has readied.
MPAPI.ReadyTracker = function()
	local self = { _ready = {} }

	-- Record (truthy) or clear (falsy) a player's ready state.
	function self:set(player_id, ready)
		self._ready[player_id] = ready and true or nil
	end

	function self:is_ready(player_id)
		return self._ready[player_id] == true
	end

	-- Drop a player entirely (e.g. on player_left).
	function self:remove(player_id)
		self._ready[player_id] = nil
	end

	-- Clear all recorded ready state.
	function self:reset()
		self._ready = {}
	end

	-- True when every player currently in the lobby has readied. An empty lobby
	-- returns false (nothing to start).
	function self:all_ready()
		local lobby = MPAPI.get_current_lobby()
		if not lobby then
			return false
		end
		local players = lobby:get_players()
		if #players == 0 then
			return false
		end
		for _, p in ipairs(players) do
			if not self._ready[p.id] then
				return false
			end
		end
		return true
	end

	return self
end

-- Tallies a unanimous vote across the current lobby roster. Each client calls
-- :record(voter_id) when a (broadcast) vote action arrives, then reads back the
-- count / total / unanimous result to drive its own UI; the host acts on unanimity.
MPAPI.VoteTracker = function()
	local self = { _votes = {} }

	function self:reset()
		self._votes = {}
	end

	function self:remove(player_id)
		self._votes[player_id] = nil
	end

	-- Record a vote and return count, total, unanimous (over players currently in
	-- the lobby). unanimous is false for an empty lobby.
	function self:record(voter_id)
		self._votes[voter_id] = true
		local lobby = MPAPI.get_current_lobby()
		if not lobby then
			return 0, 0, false
		end
		local players = lobby:get_players()
		local total = #players
		local count = 0
		for _, p in ipairs(players) do
			if self._votes[p.id] then
				count = count + 1
			end
		end
		return count, total, (total > 0 and count >= total)
	end

	return self
end

-- Mitigates the lobby-join publish race: a client's first "ready" can be sent before
-- a peer has subscribed to the actions topic, so it is never seen and the host stalls
-- waiting for it. This re-invokes send() a few times over the first several seconds
-- (idempotent on the receiver). Returns a stop() function to cancel early -- e.g. once
-- the start has landed.
--
-- opts:
--   send            function called on each attempt (re-broadcast ready)   [required]
--   should_continue function -> boolean; stop re-sending when it is false  [optional]
--   attempts        max number of sends (default 6)
--   interval        seconds between sends (default 1.2)
MPAPI.ready_resync = function(opts)
	opts = opts or {}
	local send = opts.send
	if type(send) ~= 'function' then
		return function() end
	end
	local should_continue = opts.should_continue or function()
		return true
	end
	local max_attempts = opts.attempts or 6
	local interval = opts.interval or 1.2
	local stopped = false
	local attempts = 0

	local function schedule(fn)
		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = interval,
			timer = 'REAL',
			blocking = false,
			blockable = false,
			func = function()
				fn()
				return true
			end,
		}))
	end

	local function tick()
		if stopped or attempts >= max_attempts then
			return
		end
		if not should_continue() then
			return
		end
		attempts = attempts + 1
		send()
		schedule(tick)
	end

	-- The initial ready is sent by the caller; start re-sends after a beat.
	schedule(tick)

	return function()
		stopped = true
	end
end
