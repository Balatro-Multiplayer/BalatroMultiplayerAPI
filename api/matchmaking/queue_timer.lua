-- Shared matchmaking queue-time display. While the local player is searching, this
-- ticks a "Queueing m:ss" counter into the account panel via MPAPI.set_connection_status,
-- so every consumer mod gets the elapsed-time display for free (previously each mod rolled
-- its own). It is driven off the matchmaking handle lifecycle: api.lua starts it on the
-- QUEUED event, and the tick self-terminates + clears the status once no handle is still
-- searching (matched, cancelled, or errored).
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

local _active = false
local _start_time = nil
local _last_text = nil

-- True while at least one handle is still in the queue (has not left and has not matched).
-- A matched handle carries a match_id (set in dispatch.on_match_found); a cancelled/errored
-- one is removed from mm.handles, so this cleanly covers every terminal case.
local function any_searching()
	for _, h in ipairs(mm.handles or {}) do
		if not h._left and not h.match_id then
			return true
		end
	end
	return false
end

local function format_status()
	local elapsed = math.max(0, math.floor(love.timer.getTime() - _start_time))
	return string.format('%s %d:%02d', localize('k_status_queueing'), math.floor(elapsed / 60), elapsed % 60)
end

local function schedule_tick()
	G.E_MANAGER:add_event(Event({
		trigger = 'after',
		delay = 0.25,
		blockable = false,
		blocking = false,
		func = function()
			if not _active then
				return true
			end
			if not any_searching() then
				mm.queue_timer.stop()
				return true
			end
			local t = format_status()
			if t ~= _last_text then
				_last_text = t
				MPAPI.set_connection_status(t)
			end
			schedule_tick()
			return true
		end,
	}))
end

mm.queue_timer = mm.queue_timer or {}

-- Start the elapsed-time display. Idempotent: concurrent queues (queue_all) share one
-- timer, so the start time is only stamped on the first call.
function mm.queue_timer.start()
	if _active then
		return
	end
	_active = true
	_start_time = love.timer.getTime()
	_last_text = nil
	MPAPI.set_connection_status(format_status())
	schedule_tick()
end

-- Stop the display and clear the status override.
function mm.queue_timer.stop()
	if not _active then
		return
	end
	_active = false
	_start_time = nil
	_last_text = nil
	MPAPI.set_connection_status(nil)
end

-- Public: is the local player currently searching in matchmaking? (queued, not yet matched)
function MPAPI.matchmaking.is_queued()
	return any_searching()
end
