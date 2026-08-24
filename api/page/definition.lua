-- Page registration. Mirrors MPAPI.GameMode (api/gamemode/definition.lua) -- the codebase's
-- established "mod registers a typed thing" idiom -- applied to top-level screens instead of
-- gameplay rulesets. A page is whatever currently replaces G.MAIN_MENU_UI: a mod's main menu,
-- a mod's lobby screen, or (api/page/vanilla.lua) the base game's own main menu. Transitions
-- between pages are handled by api/page/manager.lua; this file only owns the registry.
MPAPI.Pages = {}

MPAPI.Page = SMODS.GameObject:extend({
	obj_table = MPAPI.Pages,
	obj_buffer = {},
	set = 'Page',
	-- A page's key is referenced verbatim across files/mods (register_mod's main_menu_ui/
	-- lobby_ui strings, MPAPI.pages.show(key, ...) call sites, the vanilla_main_menu key in
	-- api/page/vanilla.lua) -- it must NOT get Steamodded's usual per-mod key-prefixing, the
	-- same reasoning api/replay/codes.lua's RLOGCode uses for its own cross-referenced keys.
	-- Without this, e.g. PvP's literal 'pvp_main_menu' key silently registers as
	-- 'mp_pvp_main_menu' (PvP's actual SMODS prefix is 'mp', not 'pvp'), breaking every lookup
	-- that uses the literal string as written.
	prefix_config = { key = false },
	required_params = { 'key', 'category' },

	-- 'mod_menu' | 'lobby_menu' | 'vanilla'. Lets callers ask "what kind of page is showing"
	-- (MPAPI.pages.current().category) without a separate enum to keep in sync -- what
	-- MPAPI.ViewMode used to be.
	category = nil,

	inject = function(self) end, -- obj_table is the registry, no game tables needed (api/action/registry.lua's pattern)

	-- Default build: an empty menu. Pages that set `render` instead (the vanilla main menu --
	-- see api/page/vanilla.lua -- which must reuse the base game's own menu-build procedure
	-- rather than a UIT definition) never call this.
	build = function(self)
		return {}
	end,

	-- Creates a fresh per-show instance inheriting from this definition, mirroring
	-- MPAPI.GameMode's new_instance/init split. `params` is whatever MPAPI.pages.show(key,
	-- params) was called with, available on the instance (self.params) for build/on_enter to read.
	new_instance = function(self, params)
		local instance = setmetatable({ params = params }, { __index = self })
		if instance.init then
			instance:init()
		end
		return instance
	end,
})
