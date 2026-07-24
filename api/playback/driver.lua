-- §22.2/§22.3: generic playback step-engine. Same pattern as ClaudeControl's
-- own Game:update hook + coroutine/queue machinery (lib/wait.lua's condition-
-- gated resume, lib/runner.lua's pop-one-item-at-a-time queue) -- borrowed as
-- the SHAPE, not the code: MPAPI must work standalone without ClaudeControl
-- installed, so this is a self-contained equivalent, not a dependency on it.
--
-- Walks a timeline (see timeline.lua) one action at a time, dispatching each
-- through MPAPI.playback.dispatch (registry.lua) -- driving real game actions
-- through the real engine, never a parallel fake-state renderer (matching
-- ClaudeControl's own state_dump.lua precedent: state is always re-derived by
-- driving real actions through real game logic). Waits for the previous
-- action's own event queue to drain before advancing, so playback paces
-- itself to real animation timing instead of instant-applying everything in
-- one frame.
MPAPI.playback = MPAPI.playback or {}
MPAPI.playback._active_drivers = MPAPI.playback._active_drivers or {}

local Driver = {}
Driver.__index = Driver

-- Exposed as a module field (not a local) so a test can stub it: at an idle
-- menu screen (as opposed to a real running match), the base queue always
-- carries one lingering low-priority entry that never drains on its own,
-- which would otherwise make playback pacing look permanently stuck outside
-- a live run context.
function MPAPI.playback._queues_empty()
	if not (G.E_MANAGER and G.E_MANAGER.queues) then
		return true
	end
	for _, q in pairs(G.E_MANAGER.queues) do
		if #q > 0 then
			return false
		end
	end
	return true
end

-- timeline: array of {t, player_id, opcode, args} (see timeline.lua), or an
-- initially-empty array for live spectate (see Driver:push_event below).
-- opts:
--   mod_id         -- which mod's registered handlers to dispatch through
--   pov_player_id  -- which recorded player's actions get fully applied as
--                     real input (every other player's actions are handled
--                     as a lighter HUD-only projection -- see the mod's own
--                     handlers, e.g. BalatroMultiplayerPvP/lib/playback_handlers.lua)
--   on_complete    -- called once, when the timeline is fully consumed AND
--                     the driver was told there's no more live data coming
--                     (see Driver:finish, used by finite post-hoc replay --
--                     live spectate instead just idles at the end of the
--                     timeline, waiting for more pushed events)
function MPAPI.playback.new_driver(timeline, opts)
	opts = opts or {}
	return setmetatable({
		_timeline = timeline or {},
		_cursor = 1,
		_mod_id = opts.mod_id,
		_pov_player_id = opts.pov_player_id,
		_on_complete = opts.on_complete,
		_finished_source = false, -- true once no more entries will ever arrive
		_playing = false,
	}, Driver)
end

function Driver:play()
	if self._playing then
		return
	end
	self._playing = true
	MPAPI.playback._active_drivers[self] = true
	G.CONTROLLER.locks.mpapi_playback = true
end

function Driver:pause()
	self._playing = false
	self:_update_lock()
end

function Driver:stop()
	self._playing = false
	MPAPI.playback._active_drivers[self] = nil
	self:_update_lock()
end

-- Only clears the shared input lock once no OTHER driver is still active --
-- v1 doesn't expect more than one playback session at a time, but this keeps
-- a stray second session (e.g. a bug reopening a viewer) from unlocking input
-- out from under the first.
function Driver:_update_lock()
	if not next(MPAPI.playback._active_drivers) then
		G.CONTROLLER.locks.mpapi_playback = nil
	end
end

-- Marks the timeline as complete (no more entries will ever be pushed) --
-- post-hoc replay calls this immediately (the whole timeline is already
-- known); live spectate never calls it until the spectated match itself ends.
function Driver:finish()
	self._finished_source = true
end

function Driver:is_playing()
	return self._playing
end

function Driver:has_pending()
	return self._cursor <= #self._timeline
end

-- Appends one entry for live spectate (see spectate_feed.lua) -- safe to call
-- while the driver is mid-playback, since the cursor only ever reads forward.
function Driver:push_event(entry)
	self._timeline[#self._timeline + 1] = entry
end

function Driver:_tick()
	if not self._playing or not self:has_pending() then
		if self._playing and self._finished_source and not self:has_pending() then
			self:stop()
			if self._on_complete then
				self._on_complete()
			end
		end
		return
	end
	if not MPAPI.playback._queues_empty() then
		return
	end

	local entry = self._timeline[self._cursor]
	self._cursor = self._cursor + 1

	local is_pov = (self._pov_player_id ~= nil) and (entry.player_id == self._pov_player_id)
	MPAPI.playback.dispatch(self._mod_id, entry.opcode, entry.args, {
		t = entry.t,
		player_id = entry.player_id,
		is_pov = is_pov,
		driver = self,
	})

	if self._finished_source and not self:has_pending() then
		self:stop()
		if self._on_complete then
			self._on_complete()
		end
	end
end

local _game_update_ref = Game.update
function Game:update(dt)
	_game_update_ref(self, dt)
	for driver in pairs(MPAPI.playback._active_drivers) do
		driver:_tick()
	end
end
