-- Contract test for MPAPI.set_lobby_exit_page: when a lobby with an exit page closes, the
-- player lands on that page instead of the mod's main menu, also after a run the lobby closed
-- during. Run from the MPAPI repository root: luajit tests/lobby_exit_page_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local current_page, current_lobby, overlay
local shown = {}
MPAPI = {
	_internal = {
		unlock_overlay = {
			enable_for_mod = function(id) overlay = id end,
			disable = function() overlay = nil end,
		},
	},
	pages = {
		current = function() return current_page end,
		show = function(key, params)
			shown[#shown + 1] = { key = key, params = params }
			current_page = { key = key, params = params, category = key == 'demo_lobby' and 'lobby_menu' or 'mod_menu' }
		end,
	},
	get_current_lobby = function() return current_lobby end,
	sendWarnMessage = function() end,
}
G = { STAGES = { MAIN_MENU = 'main_menu', RUN = 'run' } }
dofile('api/mod_registry/focus.lua')
local state = MPAPI._internal.mod_registry
state.update_account_button = function() end
state.registered_mods.demo = { main_menu_ui = 'demo_menu', lobby_ui = 'demo_lobby' }

-- The player is in demo's lobby, on its lobby page, in the menus.
local function in_lobby(exit_key)
	local lobby = { mod_id = 'demo' }
	G.STAGE = G.STAGES.MAIN_MENU
	state.focused_mod = 'demo'
	current_page = { key = 'demo_lobby', params = {}, category = 'lobby_menu' }
	MPAPI._internal.on_lobby_connected(lobby)
	if exit_key then
		MPAPI.set_lobby_exit_page(lobby, exit_key, { id = 't1' })
	end
	shown, current_lobby = {}, nil
	return lobby
end

-- Closes in the menus: the exit page, not the main menu.
MPAPI._internal.on_lobby_disconnected(in_lobby('demo_tournament'))
check(#shown == 1 and shown[1].key == 'demo_tournament' and shown[1].params.id == 't1', 'shows the exit page when the lobby closes on its lobby page')

-- No exit page: the mod's main menu, as before.
MPAPI._internal.on_lobby_disconnected(in_lobby(nil))
check(#shown == 1 and shown[1].key == 'demo_menu', 'without an exit page, shows the main menu')

-- Cleared with a nil key: the main menu.
local cleared = in_lobby('demo_tournament')
MPAPI.set_lobby_exit_page(cleared, nil)
MPAPI._internal.on_lobby_disconnected(cleared)
check(#shown == 1 and shown[1].key == 'demo_menu', 'a nil key clears the exit page')

-- The player moved to another page of the mod: left there.
local moved = in_lobby('demo_tournament')
current_page = { key = 'demo_settings', params = {}, category = 'mod_menu' }
MPAPI._internal.on_lobby_disconnected(moved)
check(#shown == 0, 'a player away from the lobby page is not moved')

-- Closes during a run: nothing shown now, focus dropped; the exit page once back on the menu.
local in_run = in_lobby('demo_tournament')
G.STAGE = G.STAGES.RUN
MPAPI._internal.on_lobby_disconnected(in_run)
check(#shown == 0 and state.focused_mod == nil and overlay == nil, 'during a run, nothing is shown and focus is dropped')
G.STAGE = G.STAGES.MAIN_MENU
check(MPAPI._internal.rebuild_current_menu() == true, 'back on the menu, the rebuild is handled')
check(#shown == 1 and shown[1].key == 'demo_tournament' and state.focused_mod == 'demo' and overlay == 'demo', 'back on the menu, the mod is focused and its exit page shown')
shown = {}
MPAPI._internal.rebuild_current_menu()
check(#shown == 1 and shown[1].key == 'demo_tournament', 'later rebuilds just rebuild the current page')

-- Back from the run but already in another lobby: dropped.
local busy = in_lobby('demo_tournament')
G.STAGE = G.STAGES.RUN
MPAPI._internal.on_lobby_disconnected(busy)
G.STAGE = G.STAGES.MAIN_MENU
current_lobby = { mod_id = 'demo' }
check(MPAPI._internal.rebuild_current_menu() == false and #shown == 0, 'dropped when the player is in a lobby again')

-- A run's lobby closes without an exit page: the vanilla menu, as before.
local plain = in_lobby(nil)
G.STAGE = G.STAGES.RUN
MPAPI._internal.on_lobby_disconnected(plain)
G.STAGE = G.STAGES.MAIN_MENU
check(MPAPI._internal.rebuild_current_menu() == false and #shown == 0, 'without an exit page, a run still ends on the vanilla menu')

-- A new lobby cancels an exit page waiting for the end of a run.
local earlier = in_lobby('demo_tournament')
G.STAGE = G.STAGES.RUN
MPAPI._internal.on_lobby_disconnected(earlier)
MPAPI._internal.on_lobby_connected({ mod_id = 'demo' })
check(state.pending_exit_page == nil, 'a new lobby cancels a pending exit page')

print(('ok   %d checks'):format(checks))
