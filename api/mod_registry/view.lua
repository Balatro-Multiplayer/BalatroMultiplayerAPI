-- Mod-server connection lifecycle, the account button's update trigger, and the logo offset /
-- pause hook. Actual page swapping (replacing G.MAIN_MENU_UI, tearing menus down around runs)
-- lives in api/page/manager.lua -- see MPAPI.pages.* and MPAPI.teardown_menu there.
MPAPI._internal.mod_registry = MPAPI._internal.mod_registry or {}
local state = MPAPI._internal.mod_registry

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

-- Leave a run back to the menu (go_to_menu rebuilds it via Game:main_menu -> set_main_menu_UI).
-- MPAPI.teardown_menu (used by MPAPI.cleanup below) is defined in api/page/manager.lua.
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
