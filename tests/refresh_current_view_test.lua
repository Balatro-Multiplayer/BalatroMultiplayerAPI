-- Contract test for MPAPI.refresh_current_view: it rebuilds the current menu only
-- on the main menu stage and only while a menu is on screen. Run from the MPAPI
-- repository root: luajit tests/refresh_current_view_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local rebuilds = 0
MPAPI = {
	_internal = {},
	pages = {
		current = function() return { key = 'lobby', params = {} } end,
		show = function() rebuilds = rebuilds + 1 end,
	},
}
G = { STAGES = { MAIN_MENU = 'main_menu', RUN = 'run' } }
dofile('api/mod_registry/focus.lua')
local state = MPAPI._internal.mod_registry
state.registered_mods.demo = {}
state.focused_mod = 'demo'

local function refresh(stage, menu)
	G.STAGE = stage
	G.MAIN_MENU_UI = menu
	rebuilds = 0
	return MPAPI.refresh_current_view()
end

check(refresh(G.STAGES.RUN, {}) == false and rebuilds == 0, 'no rebuild during a run')
check(refresh(G.STAGES.MAIN_MENU, nil) == false and rebuilds == 0, 'no rebuild when no menu is on screen')
check(refresh(G.STAGES.MAIN_MENU, {}) == true and rebuilds == 1, 'rebuilds the current page and returns true when a menu is on screen')

print(('ok   %d checks'):format(checks))
