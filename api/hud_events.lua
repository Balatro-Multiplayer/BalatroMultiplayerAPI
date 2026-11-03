-- Vanilla's money and round events index HUD elements that no longer exist
-- once a run is torn down (go_to_menu, a lost lobby's forfeit). An event
-- queued before the teardown that survives it crashed the game. These wraps
-- make such an event a no-op when the element it needs is gone.

local function dollars_ready()
	return G.HUD and G.GAME and G.HUD:get_UIE_by_ID('dollar_text_UI') ~= nil
end

local function round_ready()
	return G.HUD and G.GAME and G.hand_text_area and G.hand_text_area.round ~= nil
end

local unpack = _G.unpack or table.unpack

-- Wraps `fn` so that every event it queues only runs while `ready()` holds.
local function guard_events(fn, ready)
	return function(...)
		local manager = G.E_MANAGER
		local previous = rawget(manager, 'add_event')
		local add_event = manager.add_event
		manager.add_event = function(self, event, ...)
			local func = event.func
			if func then
				event.func = function(...)
					if not ready() then
						return true
					end
					return func(...)
				end
			end
			return add_event(self, event, ...)
		end
		local results = { pcall(fn, ...) }
		manager.add_event = previous
		if not results[1] then
			error(results[2], 0)
		end
		return unpack(results, 2, #results)
	end
end

ease_dollars = guard_events(ease_dollars, dollars_ready)
ease_round = guard_events(ease_round, round_ready)
