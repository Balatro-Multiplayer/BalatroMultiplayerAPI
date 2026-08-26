-- Shared state for the unlock overlay: a pure in-memory, session-scoped illusion that every
-- joker/voucher/deck/tag/seal/stake/challenge is unlocked while an MPAPI-consuming mod's
-- menu/lobby/match is active. Never touches Balatro's real save files -- see save_guard.lua for
-- why that's a hard requirement, not just a preference.
MPAPI._internal.unlock_overlay = MPAPI._internal.unlock_overlay or {}

-- nil when nothing is currently overridden; otherwise an array of { obj, field, value } entries
-- recording the REAL value each touched field had before the overlay applied it -- see
-- snapshot.lua for why "value" must be stored verbatim (some fields are functions, not booleans).
MPAPI._internal.unlock_overlay.snapshot = MPAPI._internal.unlock_overlay.snapshot or nil

-- Which registered mod id the overlay is currently active for (nil when off). Informational only
-- right now; nothing reads it yet, but toggle.lua sets it for future debugging/introspection.
MPAPI._internal.unlock_overlay.active_mod = MPAPI._internal.unlock_overlay.active_mod or nil
