-- Registers the base game's own main menu as a page, so leaving every mod's menu is "show a
-- page" like any other transition (MPAPI.pages.show('vanilla_main_menu')) instead of a
-- special-cased fallback.
--
-- `render` bypasses the generic build()->UIBox wrapping every other page uses: the base game's
-- real set_main_menu_UI (functions/common_events.lua) also builds G.PROFILE_BUTTON as a side
-- effect, so this page defers to that whole original procedure (captured in api/page/manager.lua
-- before ui/main_menu.lua rehooks it) rather than reconstructing just the buttons UIBox itself.
MPAPI.Page({
	key = 'vanilla_main_menu',
	category = 'vanilla',
	render = function(self)
		MPAPI.set_logo_offset(0, true)
		local original = MPAPI._internal.page_manager.original_set_main_menu_UI
		if original then
			original()
		end
	end,
})
