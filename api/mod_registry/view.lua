-- Menu/view swapping: replacing G.MAIN_MENU_UI with mod-supplied builders, restoring
-- the vanilla menu, tearing menus down around runs, and the logo offset / pause hook.
MPAPI._internal.mod_registry = MPAPI._internal.mod_registry or {}
local state = MPAPI._internal.mod_registry

-- Capture the game's original set_main_menu_UI here, at api/ load time, BEFORE ui/ rehooks
-- it. restore_main_menu uses this to bring back the vanilla menu. Guarded so re-execution
-- (defensive load order) never overwrites the original with an already-hooked version.
if state.original_set_main_menu_UI == nil then
	state.original_set_main_menu_UI = set_main_menu_UI
end

state.connect_to_active_mod_server = function(mod)
	if mod and mod.server_config then
		MPAPI.disconnect()
		MPAPI.connect(mod.server_config)
	end
end

state.connect_to_default_server = function(mod)
	if mod and mod.server_config then
		MPAPI.disconnect()
		MPAPI.connect()
	end
end

state.update_account_button = function()
	if MPAPI.account_button then
		MPAPI.account_button:update()
	end
end

-- Normalises a registered ui value into { build, cleanup }.
-- Accepts either a plain builder function or a { builder, cleanup } pair.
local function resolve_view(ui)
	if type(ui) == 'function' then
		return { build = ui, cleanup = nil }
	end
	if type(ui) == 'table' and type(ui[1]) == 'function' then
		return { build = ui[1], cleanup = ui[2] }
	end
	return { build = function() return {} end, cleanup = nil }
end

-- Replaces G.MAIN_MENU_UI with the result of calling the given builder.
-- If a cleanup was stored from the previous call, it is run first.
-- cleanup(uibox) may return (delay, on_enter) to animate the transition.
state.replace_main_menu = function(ui)
	local view = resolve_view(ui)

	local delay, on_enter = 0, nil
	if state.pending_cleanup and G.MAIN_MENU_UI then
		delay, on_enter = state.pending_cleanup(G.MAIN_MENU_UI)
		delay = delay or 0
	end
	state.pending_cleanup = view.cleanup

	local function do_replace()
		if G.MAIN_MENU_UI then
			G.MAIN_MENU_UI:remove()
		end
		if G.PROFILE_BUTTON then
			G.PROFILE_BUTTON:remove()
			G.PROFILE_BUTTON = nil
		end
		G.MAIN_MENU_UI = UIBox({
			definition = view.build(),
			config = { align = 'bmi', offset = { x = 0, y = 10 }, major = G.ROOM_ATTACH, bond = 'Weak' },
		})
		G.MAIN_MENU_UI.alignment.offset.y = 0
		G.MAIN_MENU_UI:align_to_major()
		if on_enter then
			on_enter(G.MAIN_MENU_UI)
		end
	end

	if delay > 0 then
		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = delay,
			func = function()
				do_replace()
				return true
			end,
		}))
	else
		do_replace()
	end
end

state.restore_main_menu = function()
	if G.MAIN_MENU_UI then
		G.MAIN_MENU_UI:remove()
	end
	MPAPI.set_logo_offset(0, true)
	if state.original_set_main_menu_UI then
		state.original_set_main_menu_UI()
	end
end

-- Pause hook: mods with prevent_pause get their own options box (or no pause) instead of
-- the vanilla one. Captured at load time; guarded so defensive re-execution does not wrap
-- our own wrapper.
if not state.options_hooked then
	state.options_hooked = true
	local original_options = G.FUNCS.options
	G.FUNCS.options = function(e)
		local mod = MPAPI.get_active_mod_data()
		if mod and mod.prevent_pause then
			local def
			if mod.options_builder and G.STAGE == G.STAGES.RUN then
				def = mod.options_builder()
			else
				def = create_UIBox_options()
			end
			G.FUNCS.overlay_menu{ definition = def }
		else
			original_options(e)
		end
	end
end

MPAPI.set_logo_offset = function(y, immediate)
	if G.title_top then
		if not G.title_top._mpapi_base_y then
			G.title_top._mpapi_base_y = G.title_top.T.y
		end
		G.title_top.T.y = G.title_top._mpapi_base_y + y
		if immediate then
			G.title_top.VT.y = G.title_top.T.y
		end
	end
	if G.SPLASH_LOGO then
		if not G.SPLASH_LOGO._mpapi_base_y then
			G.SPLASH_LOGO._mpapi_base_y = G.SPLASH_LOGO.T.y
		end
		G.SPLASH_LOGO.T.y = G.SPLASH_LOGO._mpapi_base_y + y
		if immediate then
			G.SPLASH_LOGO.VT.y = G.SPLASH_LOGO.T.y
		end
	end
end

-- Remove the menu UI the base game's delete_run drops when a run starts (it does so via
-- remove_all on the main-menu stage objects, but that also kills G.ROOM_ATTACH, which is only
-- safe because delete_run is immediately followed by prep_stage -- so target the elements here).
-- Game:main_menu recreates them on the next menu entry.
MPAPI.teardown_menu = function()
	for _, key in ipairs({ 'MAIN_MENU_UI', 'PROFILE_BUTTON', 'title_top', 'SPLASH_LOGO' }) do
		if G[key] then
			pcall(function() G[key]:remove() end)
			G[key] = nil
		end
	end
	-- The version display is an anonymous top-right ('tri') UIBox among the menu's stage objects.
	local menu_objects = G.STAGE_OBJECTS and G.STAGES and G.STAGE_OBJECTS[G.STAGES.MAIN_MENU]
	for i = menu_objects and #menu_objects or 0, 1, -1 do
		local o = menu_objects[i]
		if o and o.config and o.config.align == 'tri' then
			pcall(function() o:remove() end)
		end
	end
	state.pending_cleanup = nil
end

-- Leave a run back to the menu (go_to_menu rebuilds it via Game:main_menu -> set_main_menu_UI).
MPAPI.exit_to_menu = function()
	if G.STAGE == G.STAGES.RUN and G.FUNCS.go_to_menu then
		G.FUNCS.go_to_menu()
	end
end

-- Tear down whichever context is active: the run if in a run, otherwise the menu.
MPAPI.cleanup = function()
	if G.STAGE == G.STAGES.RUN then
		MPAPI.exit_to_menu()
	else
		MPAPI.teardown_menu()
	end
end
