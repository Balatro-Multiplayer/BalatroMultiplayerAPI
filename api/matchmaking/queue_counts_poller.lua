-- Reusable "poll MPAPI.matchmaking.get_queue_counts on an interval" helper,
-- for a menu screen (e.g. a Find Game menu) that wants to show live
-- queue/in-game counts on its buttons while it's open. Unlike
-- queue_timer.lua's single shared "am I searching" status (there's only ever
-- one of those at a time), this is a factory: each caller gets its own
-- independent poller instance, since more than one menu/mod could
-- conceivably want one running concurrently.
--
-- Liveness is caller-driven (explicit stop()), not auto-detected from game
-- state -- a menu's own open/close lifecycle is a far simpler and more
-- robust signal than trying to infer "is this overlay still showing."
MPAPI.matchmaking = MPAPI.matchmaking or {}

-- mod_id: passed straight to get_queue_counts.
-- interval_seconds: delay between ticks (an immediate first fetch happens
--   on start(), not after waiting one interval).
-- callback(err, game_modes): called after every poll, success or failure.
--   game_modes is the response's `gameModes` table on success, nil on
--   error -- this helper does not retry or suppress errors, the caller
--   decides how to render either case.
--
-- Returns a handle: { start = function() ... end, stop = function() ... end }.
MPAPI.matchmaking.create_queue_counts_poller = function(mod_id, interval_seconds, callback)
	local handle = { _active = false }

	local function fetch()
		MPAPI.matchmaking.get_queue_counts(mod_id, function(err, data)
			-- Guards against a request that was still in flight when stop()
			-- was called -- must not call back into a UI element that may
			-- have already been torn down (the menu closed).
			if not handle._active then
				return
			end
			callback(err, data and data.gameModes or nil)
		end)
	end

	local function schedule_tick()
		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = interval_seconds,
			blockable = false,
			blocking = false,
			func = function()
				if not handle._active then
					return true
				end
				fetch()
				schedule_tick()
				return true
			end,
		}))
	end

	function handle.start()
		if handle._active then
			return
		end
		handle._active = true
		fetch()
		schedule_tick()
	end

	function handle.stop()
		handle._active = false
	end

	return handle
end
