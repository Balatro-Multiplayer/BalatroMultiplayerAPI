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

-- Defaults for Driver:fast_forward_to (below) -- exposed on MPAPI.playback rather than on
-- the (module-local, never exported) Driver table itself, matching this file's existing
-- external-surface convention (everything public hangs off MPAPI.playback.*). Deliberately
-- overridable at runtime, not baked into fast_forward_to's own defaulting, since the safe
-- multiplier is an empirical question this codebase has never answered before (see SPDRN's
-- validation harness) -- a caller (or a future settings UI) can raise/lower
-- MPAPI.playback.DEFAULT_FF_GAMESPEED once a value is proven safe, without touching this file.
--
-- Confirmed live (2026-09-03): escalated 4/8/16/32/64/128/256 against a real production SPDRN
-- match replayed via MPAPI.playback.build_timeline (local Postgres import, no server round-trip)
-- -- deliberately one of the WORSE-behaved real recordings available (repeatedly triggers this
-- codebase's own existing card-ref-resolution desync warnings and multiple 10s
-- shop/blind-select readiness timeouts), specifically because a match that's ALREADY stressing
-- the pause/retry machinery is a harder test of "does raising GAMESPEED corrupt vanilla's own
-- delay()/tween sequencing" than a clean one. Every multiplier from 4 through 256 completed with
-- zero crashes and landed at IDENTICAL final state (G.GAME.dollars, ante, joker keys, hand
-- count) -- both matching each other and matching a true gamespeed=1 baseline run of the same
-- match. Wall-clock plateaus around 16x-32x (real 10s-scoped waits like
-- SHOP_READY_TIMEOUT_SECONDS in playback_handlers.lua are immune to GAMESPEED by construction,
-- exactly as designed -- confirmed live, not just assumed), so going higher than that buys
-- negligible further speedup while narrowing the safety margin for no real benefit. 16 is picked
-- as the new default: solidly inside the validated, zero-crash range (with a full 4x-16x margin
-- below the highest multiplier actually tested clean), while already capturing the large majority
-- of the available wall-clock improvement (this specific stress match: ~140s at 1x down to ~40s
-- at 16x). See this session's validation report for the full methodology, including the one real
-- crash bug this same testing found and fixed (Driver:_dispatch_next's own nil-player_id guard,
-- below) -- unrelated to GAMESPEED itself (reproduced identically at gamespeed=1), but found via
-- this same effort.
MPAPI.playback.DEFAULT_FF_GAMESPEED = 16
MPAPI.playback.DEFAULT_FF_WATCHDOG_SECONDS = 15

-- Exposed as a module field (not a local) so a test can stub it: the base
-- queue always carries a couple of lingering low-priority housekeeping
-- entries (confirmed live at both the main menu AND BLIND_SELECT -- e.g. a
-- `no_delete=true` entry and a ~2-minute-interval timer entry, neither ever
-- actually removed from the queue), which would otherwise make playback
-- pacing look permanently stuck. Only `blocking` entries represent real
-- in-progress animation/scoring work -- confirmed live by snapshotting the
-- base queue mid-hand-play: every genuine gameplay event (chip/mult
-- animations, scoring, etc.) has blocking=true, while every persistent
-- housekeeping entry has blocking=false. So "busy" means "has a blocking
-- entry", not "queue is non-empty".
function MPAPI.playback._queues_empty()
	if not (G.E_MANAGER and G.E_MANAGER.queues) then
		return true
	end
	for _, q in pairs(G.E_MANAGER.queues) do
		for _, ev in ipairs(q) do
			if ev.blocking then
				return false
			end
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
--   schema_version -- the recording's own match_manifest.schema_version (see
--                     api/replay/framing_codes.lua), passed through to every
--                     dispatched handler as ctx.schema_version so each
--                     MPAPI.RLOG_CODE's replay() can branch on it (see
--                     codes.lua) instead of carrying a per-opcode version
--                     field. Defaults to RLOG.SCHEMA_VERSION (the running
--                     client's own current version) so callers that don't
--                     pass one (e.g. live spectate, which has no recorded
--                     manifest to read) still get a sane value.
--   on_complete    -- called once, when the timeline is fully consumed AND
--                     the driver was told there's no more live data coming
--                     (see Driver:finish, used by finite post-hoc replay --
--                     live spectate instead just idles at the end of the
--                     timeline, waiting for more pushed events)
--   on_after_dispatch(entry, ctx) -- called after EVERY dispatched entry (normal pacing or
--                     inside a fast_forward_to run, same call site either way), with the same
--                     `entry`/`ctx` MPAPI.playback.dispatch itself was just given. Lets a
--                     caller observe live game state as a side effect of real dispatch --
--                     e.g. SPDRN's own ante-index builder (objects/replay_log/ante_index.lua)
--                     reads G.GAME.round_resets.ante here to learn where each ante starts --
--                     without this file needing to know anything about antes, runs, or any
--                     other mod-specific concept.
function MPAPI.playback.new_driver(timeline, opts)
	opts = opts or {}
	return setmetatable({
		_timeline = timeline or {},
		_cursor = 1,
		_mod_id = opts.mod_id,
		_pov_player_id = opts.pov_player_id,
		_schema_version = opts.schema_version or MPAPI.replay.SCHEMA_VERSION,
		_on_complete = opts.on_complete,
		_on_after_dispatch = opts.on_after_dispatch,
		_finished_source = false, -- true once no more entries will ever arrive
		_playing = false,
		-- One RLOG.new_resolver_state() per recorded player_id, lazily created in
		-- _tick below -- see resolve_card_ref's own comment for why these can
		-- never be shared across players or reused for a different playback.
		_card_resolvers = {},
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
	-- Cleanup only (restores GAMESPEED if a fast-forward boost is still in effect) -- does
	-- NOT fire opts.on_done, since an external stop means "abandoned mid-seek", not "reached
	-- the target". See _ff_cleanup's own comment for why this matters: a real, live run's
	-- G.SETTINGS.GAMESPEED is a genuine player-facing preference, not scratch state this
	-- system is allowed to leave clobbered if the player exits the replay viewer mid-seek.
	self:_ff_cleanup()
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

-- Dispatches exactly one timeline entry and advances the cursor -- the one piece of actual
-- dispatch work, shared verbatim by normal _tick() pacing and fast_forward_to's tight loop
-- (_fast_forward_tick below). Callers are responsible for their own pacing/gating around this;
-- this method itself does none.
function Driver:_dispatch_next()
	local entry = self._timeline[self._cursor]
	self._cursor = self._cursor + 1

	-- Confirmed live (crashed a real run): entry.player_id can be nil if a caller builds its own
	-- timeline off a bad/incomplete connection identity (e.g. SPDRN._launch_rejoin computing
	-- my_id from a connection whose own player_id hadn't been set yet -- fixed there too, see
	-- that file's own comment, but this guard is deliberately NOT redundant with it: this is the
	-- only place that knows a nil player_id is fatal to a raw table-key assignment, so it's the
	-- last line of defense for ANY current or future caller, not just this one already-fixed
	-- case). Without this, `self._card_resolvers[entry.player_id] = ...` below raises "table
	-- index is nil" and crashes the whole game outright -- skip-and-warn instead, matching every
	-- other desync-tolerance path in this codebase's replay handlers (never a hard crash over a
	-- data-quality problem).
	if entry.player_id == nil then
		MPAPI.sendWarnMessage(
			'[playback] dispatch: timeline entry ' .. tostring(self._cursor - 1) .. ' (opcode '
				.. tostring(entry.opcode) .. ') has no player_id -- skipping rather than crashing'
		)
		if self._on_after_dispatch then
			self._on_after_dispatch(entry, { t = entry.t, player_id = nil, is_pov = false, driver = self, schema_version = self._schema_version })
		end
		return
	end

	local is_pov = (self._pov_player_id ~= nil) and (entry.player_id == self._pov_player_id)
	local card_resolver = self._card_resolvers[entry.player_id]
	if not card_resolver then
		card_resolver = MPAPI.replay.new_resolver_state()
		self._card_resolvers[entry.player_id] = card_resolver
	end
	local ctx = {
		t = entry.t,
		player_id = entry.player_id,
		is_pov = is_pov,
		driver = self,
		schema_version = self._schema_version,
		card_resolver = card_resolver,
	}
	MPAPI.playback.dispatch(self._mod_id, entry.opcode, entry.args, ctx)
	if self._on_after_dispatch then
		self._on_after_dispatch(entry, ctx)
	end
end

function Driver:_check_complete()
	if self._finished_source and not self:has_pending() then
		self:stop()
		if self._on_complete then
			self._on_complete()
		end
		return true
	end
	return false
end

function Driver:_tick()
	if not self._playing or not self:has_pending() then
		if self._playing then
			self:_check_complete()
		end
		return
	end

	if self._ff_active then
		self:_fast_forward_tick()
		self:_check_complete()
		return
	end

	if not MPAPI.playback._queues_empty() then
		return
	end

	self:_dispatch_next()
	self:_check_complete()
end

-- Fast-forwards this driver to `target_cursor` (a Driver._cursor value -- i.e. "stop once
-- self._cursor >= target_cursor") without waiting a full real frame between dispatches
-- whenever nothing is actually blocking, and with G.SETTINGS.GAMESPEED temporarily boosted so
-- genuinely-blocking/animated vanilla events (delay()/tween-based scoring, etc) resolve in
-- fewer real seconds too. See SPDRN's objects/replay_log/ante_index.lua (building an ante
-- index) and ante_seek.lua (seeking to one) for the two current callers and the full design
-- rationale (BMP replay-seek design doc).
--
-- Deliberately NOT the same mechanism as ClaudeControl's own cctl-run speed hooks
-- (lib/params.lua's install_anim_skip) -- that forces every event's blocking/blockable/delay
-- to false/false/0 outright, which is confirmed (see suites/pvp/playback_full_fidelity.lua's
-- own header comment) to occasionally corrupt vanilla's own delay()/tween-based round-eval
-- sequencing badly enough to crash to the main menu. This method changes neither: it only (a)
-- removes the ARTIFICIAL one-frame wait between dispatches when there's genuinely nothing to
-- wait for, and (b) raises G.SETTINGS.GAMESPEED, a real vanilla-native setting that speeds up
-- how fast G.TIMERS.TOTAL accumulates (see functions/button_callbacks.lua's own
-- change_gamespeed comment) -- every event's own blocking/delay VALUE is untouched, only how
-- quickly the shared clock those values are compared against advances.
--
-- Forward-only, like every other primitive on this class: if target_cursor is already
-- reached, resolves immediately via opts.on_done. A caller wanting to reach an EARLIER point
-- must restart the whole session from its recorded seed and fast-forward back up to the
-- target -- there is no partial/checkpointed resume anywhere in this codebase (state is
-- always re-derived by driving real actions through the real engine, per this file's own
-- header comment), so true in-place rewind isn't possible; this method only ever moves the
-- cursor forward.
--
-- opts:
--   gamespeed         -- G.SETTINGS.GAMESPEED while fast-forwarding (default
--                        MPAPI.playback.DEFAULT_FF_GAMESPEED)
--   watchdog_seconds  -- real seconds (love.timer.getTime()) with no cursor progress before
--                        giving up on the tight loop/gamespeed boost and degrading to today's
--                        normal one-opcode-per-real-frame dispatch for the rest of this seek
--                        (default MPAPI.playback.DEFAULT_FF_WATCHDOG_SECONDS) -- same
--                        real-time-timeout-then-degrade discipline already used throughout
--                        SPDRN's own playback_handlers.lua (SHOP_READY_TIMEOUT_SECONDS etc),
--                        applied here instead of a frame-count throttle for the same reason:
--                        frame timing says nothing about vanilla's own wall-clock delays.
--   pause_gate()      -- optional; returning true means "don't dispatch another entry THIS
--                        frame, wait for the next real frame instead." Exists because a tight
--                        same-frame loop can race ahead of any of this codebase's own
--                        deferred-by-one-real-frame pollers -- confirmed for SPDRN's own
--                        run-transition flag (SPDRN._pending_run_transition, consumed by
--                        SPDRN._check_pending_run_transition, itself polled once per real
--                        Game:update frame from SPDRN's core.lua, one frame after
--                        request_run_transition sets it). Today's normal ≤1-opcode-per-frame
--                        cadence is safe from this by construction (every such poller already
--                        runs before the NEXT dispatch); a literal tight loop inside one
--                        _tick() is not, without this gate. Defaults to a no-op (always
--                        false), which keeps every caller that doesn't pass one at today's
--                        safe cadence.
--   on_progress(cursor, target)  -- called after every entry dispatched during this seek
--   on_stalled(cursor, target)   -- called once, only if the watchdog actually fires
--   on_done(cursor)              -- called once target_cursor is reached (or the timeline
--                                    runs out first, or it was already reached when called)
function Driver:fast_forward_to(target_cursor, opts)
	opts = opts or {}
	target_cursor = math.min(target_cursor, #self._timeline + 1)
	if target_cursor <= self._cursor then
		if opts.on_done then
			opts.on_done(self._cursor)
		end
		return
	end

	self._ff_active = true
	self._ff_target = target_cursor
	self._ff_opts = opts
	self._ff_degraded = false
	self._ff_saved_gamespeed = G.SETTINGS.GAMESPEED
	G.SETTINGS.GAMESPEED = opts.gamespeed or MPAPI.playback.DEFAULT_FF_GAMESPEED
	self._ff_last_progress_at = love.timer.getTime()
	self:play()
end

-- One real frame's worth of fast-forward work, called from _tick() instead of the normal
-- single-dispatch body while _ff_active. See fast_forward_to's own header comment for the
-- full rationale of every piece of this.
function Driver:_fast_forward_tick()
	local opts = self._ff_opts
	local watchdog = opts.watchdog_seconds or MPAPI.playback.DEFAULT_FF_WATCHDOG_SECONDS

	if not self._ff_degraded and (love.timer.getTime() - self._ff_last_progress_at) > watchdog then
		self._ff_degraded = true
		G.SETTINGS.GAMESPEED = self._ff_saved_gamespeed
		local stalled_entry = self._timeline[self._cursor]
		MPAPI.sendWarnMessage(
			'[fast_forward] stalled at cursor ' .. tostring(self._cursor) .. '/' .. tostring(self._ff_target)
				.. ' (opcode ' .. tostring(stalled_entry and stalled_entry.opcode) .. ') after '
				.. tostring(watchdog) .. 's -- degrading to normal-pace dispatch for the rest of this seek'
		)
		if opts.on_stalled then
			opts.on_stalled(self._cursor, self._ff_target)
		end
	end

	if self._ff_degraded then
		-- Degraded: same cadence/gating as ordinary playback (≤1 dispatch per real frame,
		-- gated on queues being empty), just still bounded by _ff_target rather than running
		-- to the end of the whole timeline.
		if MPAPI.playback._queues_empty() and self:has_pending() and self._cursor < self._ff_target then
			self:_dispatch_next()
		end
	else
		while self._playing and self._ff_active
			and self._cursor < self._ff_target
			and self:has_pending()
			and MPAPI.playback._queues_empty()
			and not (opts.pause_gate and opts.pause_gate())
		do
			self:_dispatch_next()
			self._ff_last_progress_at = love.timer.getTime()
			if opts.on_progress then
				opts.on_progress(self._cursor, self._ff_target)
			end
		end
	end

	if self._cursor >= self._ff_target or not self:has_pending() then
		self:_end_fast_forward()
	end
end

-- Restores GAMESPEED if a boost is currently in effect and clears all _ff_* state -- shared
-- by normal/degraded completion (fires opts.on_done) and Driver:stop() (does not -- see
-- stop()'s own comment).
function Driver:_ff_cleanup()
	if self._ff_active and not self._ff_degraded then
		G.SETTINGS.GAMESPEED = self._ff_saved_gamespeed
	end
	self._ff_active = nil
	self._ff_target = nil
	self._ff_opts = nil
	self._ff_saved_gamespeed = nil
	self._ff_degraded = nil
end

function Driver:_end_fast_forward()
	if not self._ff_active then
		return
	end
	local opts, cursor = self._ff_opts, self._cursor
	self:_ff_cleanup()
	if opts and opts.on_done then
		opts.on_done(cursor)
	end
end

local _game_update_ref = Game.update
function Game:update(dt)
	_game_update_ref(self, dt)
	for driver in pairs(MPAPI.playback._active_drivers) do
		driver:_tick()
	end
end
