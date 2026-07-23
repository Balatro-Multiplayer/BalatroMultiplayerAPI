--[[
  Hover-popup vertical clamp test.

  The engine's Moveable alignment flips a hover popup above ('tm') or below
  ('bm') its tile but only clamps horizontally, so a popup taller than the
  space on its side of the tile runs off screen (the weekly cocktail's full
  composition hovered from the bottom tile row). And because the popup is
  position-bonded to its tile, which MOVES while the popup is open (selecting
  a tile raises it), the clamp must hold frame-by-frame, not once at hover:
  card:hover wraps the popup's move and re-clamps after every frame with
  BP._popup.clamp_y -- the pure decision under test here.

  Contract: clamp_y(y, h, room_h, edge) returns the y keeping [y, y+h] inside
  [edge, room_h - edge]; bottom edge applies first so the TOP edge wins for
  popups taller than the room (the top of the content must stay readable).

  Run from the repo root:
    luajit dev/test_banpick_popup_clamp.lua
]]

-- ── Stubs to load the real module ───────────────────────────────────────────
MPAPI = {
	_TEST = true,
	sendWarnMessage = function() end,
}
localize = function(k) return k end
G = {
	FUNCS = {},
	C = { GREEN = 'green', RED = 'red', MULT = 'mult', BLUE = 'blue', WHITE = 'white', BLACK = 'black', CLEAR = 'clear', UI = { BACKGROUND_INACTIVE = 'inactive', TEXT_LIGHT = 'light' } },
}

dofile('api/ban_pick.lua')
local clamp_y = MPAPI.BanPick._popup.clamp_y

local failures = 0
local function check(cond, msg)
	if not cond then
		failures = failures + 1
		print('FAIL: ' .. msg)
	end
end

-- Quarter-unit fixtures throughout: exactly representable in binary floating
-- point, so the geometry identities hold under == with no tolerance.
local EDGE = 0.25
local ROOM_H = 11.5 -- typical G.ROOM.T.h in game units

-- A popup fully on screen is untouched.
check(clamp_y(3, 5, ROOM_H, EDGE) == 3, 'fitting popup is untouched')
check(clamp_y(EDGE, 5, ROOM_H, EDGE) == EDGE, 'popup exactly at the top edge is untouched')
check(clamp_y(ROOM_H - EDGE - 5, 5, ROOM_H, EDGE) == ROOM_H - EDGE - 5, 'popup exactly at the bottom edge is untouched')

-- The bug scenario: tall popup pushed above the screen (tile raised while
-- hovered, or bottom-row tile with the cocktail composition) -> pulled down
-- to the top edge.
check(clamp_y(-2, 9, ROOM_H, EDGE) == EDGE, 'popup above the screen is pulled down to the top edge')

-- Overflow past the bottom -> pushed up to the bottom edge.
check(clamp_y(8, 9, ROOM_H, EDGE) == ROOM_H - EDGE - 9, 'popup past the bottom is pushed up to the bottom edge')

-- Taller than the whole room: cannot fit, so the TOP edge must win -- the
-- player reads content top-down.
check(clamp_y(-4, 20, ROOM_H, EDGE) == EDGE, 'taller-than-room popup pins to the top edge')
check(clamp_y(5, 20, ROOM_H, EDGE) == EDGE, 'taller-than-room popup pins to the top edge regardless of start y')

-- Idempotence: clamping a clamped position changes nothing (the wrap runs
-- every frame, so a fixed point is required or the popup would creep).
for _, y in ipairs({ -2, 0, 3, 8, 15 }) do
	for _, h in ipairs({ 2, 9, 20 }) do
		local once = clamp_y(y, h, ROOM_H, EDGE)
		check(clamp_y(once, h, ROOM_H, EDGE) == once, 'idempotent at y=' .. y .. ' h=' .. h)
	end
end

if failures == 0 then
	print('OK: all popup clamp checks passed')
else
	os.exit(1)
end
