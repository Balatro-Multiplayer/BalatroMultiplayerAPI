-- Contract test: MPAPI.show_notice opens one overlay for a notice, however
-- many times the same title and text are raised while it is still up, and
-- opens a new one once it is gone. Run from the MPAPI repository root:
-- luajit tests/show_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local opened = 0
MPAPI = {}
MPAPI.ui_element = function()
	return {
		as_overlay = function()
			opened = opened + 1
			G.OVERLAY_MENU = {}
		end,
	}
end
G = { FUNCS = {}, UIT = {}, C = {} }
dofile('ui/banned_notice_overlay.lua')

MPAPI.show_notice('k_group_queue_failed_title', 'Bob runs a different MultiplayerPvP version.')
MPAPI.show_notice('k_group_queue_failed_title', 'Bob runs a different MultiplayerPvP version.')
check(opened == 1, 'the same notice twice opens one overlay, got ' .. opened)

MPAPI.show_notice('k_group_queue_failed_title', 'Another text.')
check(opened == 2, 'a different text opens its own overlay')

G.OVERLAY_MENU = nil
MPAPI.show_notice('k_group_queue_failed_title', 'Another text.')
check(opened == 3, 'the same notice opens again once the overlay is gone')

G.OVERLAY_MENU = {}
MPAPI.show_notice('k_group_queue_failed_title', 'Another text.')
check(opened == 4, 'another overlay on top is not this notice')

print(('ok   %d checks'):format(checks))
