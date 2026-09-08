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
	-- A mod's optional two-part title (register_mod{title={base,extra}}, api/title.lua) has a
	-- second sprite bonded to G.title_top as its alignment "major" (bond='Strong'), unlike
	-- G.SPLASH_LOGO above -- a bonded Moveable recalculates its own T.y from
	-- major.T.y + alignment.offset.y, so poking its T.y directly (the approach that works for
	-- G.title_top/G.SPLASH_LOGO, neither of which is bonded to anything) gets silently
	-- overwritten the next time anything realigns it. Confirmed live: T.y/VT.y both read back
	-- exactly the intended offset immediately after setting them that way, but the rendered
	-- title still showed the extra half sitting at its original position.
	--
	-- The fix is NOT to also offset extra.alignment.offset.y by y -- G.title_top (extra's major)
	-- already moved by y two lines above, so adding y again to extra's own offset double-counts
	-- it: extra ends up shifted by 2y total while the base half only moved by y, visibly pulling
	-- the two halves apart instead of moving them as one unit (confirmed live: this was the
	-- first fix attempted here, and the "VS" extra sprite ended up almost entirely off the top
	-- of the screen while the base "PLAYER...PLAYER" half was correctly positioned). Leaving
	-- extra's own offset untouched and just re-deriving its position from title_top's
	-- already-updated T.y is what actually preserves the original base/extra relative layout.
	local extra = MPAPI._internal.get_title_extra_sprite and MPAPI._internal.get_title_extra_sprite()
	if extra and extra.alignment and immediate then
		extra:align_to_major()
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
