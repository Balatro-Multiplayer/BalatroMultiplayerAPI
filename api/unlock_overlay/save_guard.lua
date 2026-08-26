-- The safety net that makes the unlock overlay actually safe, independent of whether every
-- on/off hook in focus.lua fires correctly. Game:save_progress() (game.lua) builds its save
-- snapshot by reading DIRECTLY off the live .unlocked/.discovered/.alerted fields this overlay
-- mutates -- there is no separate authoritative dict shielding that mutation from a save. Many
-- ordinary UI interactions call it, not just "a run ended" (hovering an alerted collection tile,
-- quitting, an achievement popping, a tutorial step) -- so correctness can't rely on carefully
-- avoiding those moments while the overlay happens to be on.
--
-- Sandwiches every save between a revert and a re-apply: whatever calls save_progress only ever
-- sees the player's real unlock state, and the overlay (if it was on) comes right back after.
-- Confirmed save_progress is fully synchronous with no self-call/yield, so this is safe to nest
-- around; revert()/apply() are themselves idempotent, so back-to-back calls from unrelated saves
-- firing in quick succession are harmless.
if not MPAPI._unlock_overlay_save_guard_hooked then
	MPAPI._unlock_overlay_save_guard_hooked = true
	local _ref = Game.save_progress
	function Game:save_progress(...)
		local ov = MPAPI._internal.unlock_overlay
		if ov.snapshot then
			ov.revert()
			local ret = _ref(self, ...)
			ov.apply()
			return ret
		end
		return _ref(self, ...)
	end
end
