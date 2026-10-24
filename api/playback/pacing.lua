-- Playback pacing: decides when the next recorded entry is due. A virtual clock
-- advances with real frame time scaled by the chosen speed, and an entry is due once
-- the clock reaches its recorded offset from the first entry. Pure: no game state.
MPAPI.playback = MPAPI.playback or {}

MPAPI.playback.Speed = MPAPI.playback.Speed or {
	X1 = '1x',
	X2 = '2x',
	X4 = '4x',
	FAST_FORWARD = 'fast_forward',
}
local Speed = MPAPI.playback.Speed

local CLOCK_MULTIPLIER = {
	[Speed.X1] = 1,
	[Speed.X2] = 2,
	[Speed.X4] = 4,
}

local Pacing = {}
Pacing.__index = Pacing

-- origin_ms: the recorded time of the first entry, the zero point of the clock.
function MPAPI.playback.new_pacing(origin_ms)
	return setmetatable({
		_origin_ms = origin_ms or 0,
		_clock_ms = 0,
		_speed = Speed.X1,
	}, Pacing)
end

function Pacing:set_speed(speed)
	assert(speed == Speed.FAST_FORWARD or CLOCK_MULTIPLIER[speed], 'unknown playback speed: ' .. tostring(speed))
	self._speed = speed
end

function Pacing:get_speed()
	return self._speed
end

function Pacing:advance(dt_seconds)
	local multiplier = CLOCK_MULTIPLIER[self._speed]
	if multiplier then
		self._clock_ms = self._clock_ms + dt_seconds * 1000 * multiplier
	end
end

function Pacing:is_due(entry_t_ms)
	if self._speed == Speed.FAST_FORWARD then
		return true
	end
	return self._clock_ms >= entry_t_ms - self._origin_ms
end

-- After an entry is dispatched (or skipped by a seek), the clock is never behind it,
-- so playback resumes from there instead of waiting out the skipped time.
function Pacing:sync_to(entry_t_ms)
	self._clock_ms = math.max(self._clock_ms, entry_t_ms - self._origin_ms)
end
