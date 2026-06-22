-- Forward declarations for helper functions
local connect_to_active_mod_server
local connect_to_default_server
local update_account_button
local replace_main_menu
local restore_main_menu
local resolve_view

-----------------------------
-- STATE VARIABLES
-----------------------------

local _registered_mods = {}
local _mod_order = {}
local _focused_mod = nil     -- which mod's UI is currently shown; nil = game main menu
local _engaged_mod = nil     -- which mod has an active lobby; nil = no lobby
local _current_view = nil    -- 'mod_menu' | 'lobby_menu' | nil
local _pending_cleanup = nil -- cleanup fn stored from the last replace_main_menu call
local _default_server_config = nil
local _original_set_main_menu_UI = set_main_menu_UI

-- Official (first-party) mods. `coming_soon = true` makes an *uninstalled* official
-- mod display "Coming Soon" in the menu instead of a download-page link, and stops
-- its button from opening the download URL. Flip it to false (or remove it) once the
-- mod is published. Installed mods (the player has the folder) ignore this flag.
local _official_mods = {
	{ id = 'MultiplayerPvP', name = 'PvP', colour = G.C.RED, download_url = 'https://github.com/V-rtualized/MultiplayerPvP', coming_soon = true },
	{ id = 'MultiplayerSpeedrunning', name = 'Speedrun', colour = G.C.GREEN, download_url = 'https://github.com/V-rtualized/MultiplayerSpeedrunning' },
	{ id = 'MultiplayerCoop', name = 'Co-op', colour = G.C.BLUE, download_url = 'https://github.com/V-rtualized/MultiplayerCoop', coming_soon = true },
}

for _, official in ipairs(_official_mods) do
	_registered_mods[official.id] = {
		id = official.id,
		name = official.name,
		colour = official.colour,
		download_url = official.download_url,
		coming_soon = official.coming_soon or false,
		server_config = nil,
		main_menu_ui = nil,
		lobby_ui = nil,
		is_official = true,
	}
end

-----------------------------
-- API FUNCTIONS
-----------------------------

MPAPI.register_mod = function(opts)
	if not opts.id then
		MPAPI.sendWarnMessage('register_mod: missing id')
		return
	end
	if not opts.main_menu_ui then
		MPAPI.sendWarnMessage('register_mod: missing main_menu_ui for ' .. opts.id)
		return
	end

	local existing = _registered_mods[opts.id]
	if existing and existing.is_official then
		existing.main_menu_ui = opts.main_menu_ui
		existing.lobby_ui = opts.lobby_ui
		existing.server_config = opts.server_config
		existing.prevent_pause = opts.prevent_pause or false
		existing.options_builder = opts.options_builder or nil
		if opts.name then existing.name = opts.name end
		if opts.colour then existing.colour = opts.colour end
	else
		_registered_mods[opts.id] = {
			id = opts.id,
			name = opts.name or opts.id,
			colour = opts.colour or G.C.PURPLE,
			server_config = opts.server_config,
			main_menu_ui = opts.main_menu_ui,
			lobby_ui = opts.lobby_ui,
			download_url = opts.download_url,
			prevent_pause = opts.prevent_pause or false,
			options_builder = opts.options_builder or nil,
			is_official = false,
		}
		_mod_order[#_mod_order + 1] = opts.id
	end

	update_account_button()
end

-- Returns the engaged mod id (has an active lobby). This is what mods
-- should check inside hooked game functions to gate their logic.
MPAPI.get_active_mod = function()
	return _engaged_mod
end

-- Convenience check for mods hooking game functions.
MPAPI.is_active = function(mod_id)
	return _engaged_mod == mod_id
end

-- Returns the focused mod id (whose menu is currently shown).
MPAPI.get_focused_mod = function()
	return _focused_mod
end

-- Returns 'mod_menu', 'lobby_menu', or nil (game main menu).
MPAPI.get_current_view = function()
	return _current_view
end

MPAPI.get_active_mod_data = function()
	if not _engaged_mod then return end
	return _registered_mods[_engaged_mod]
end

MPAPI.get_registered_mods = function()
	local result = {}
	for _, official in ipairs(_official_mods) do
		result[#result + 1] = _registered_mods[official.id]
	end
	for _, id in ipairs(_mod_order) do
		result[#result + 1] = _registered_mods[id]
	end
	return result
end

-----------------------------
-- INTERNAL FUNCTIONS
-----------------------------

MPAPI._internal.activate_mod = function(id)
	local mod = _registered_mods[id]
	if not mod then
		MPAPI.sendWarnMessage('activate_mod: unknown mod ' .. tostring(id))
		return
	end

	if not mod.main_menu_ui then
		-- Coming-soon mods are not yet downloadable: do nothing on activate.
		if not mod.coming_soon and mod.download_url then
			love.system.openURL(mod.download_url)
		end
		return
	end

	-- Re-entering an engaged lobby from the game main menu: skip mod menu
	-- and go straight to the lobby view.
	if id == _engaged_mod and mod.lobby_ui then
		_focused_mod = id
		_current_view = 'lobby_menu'
		_pending_cleanup = nil
		replace_main_menu(mod.lobby_ui)
		update_account_button()
		return
	end

	connect_to_active_mod_server(mod)
	_focused_mod = id
	_current_view = 'mod_menu'
	replace_main_menu(mod.main_menu_ui)
	update_account_button()
end

-- Returns to the game main menu. Does NOT leave an active lobby.
MPAPI._internal.deactivate_mod = function()
	if not _focused_mod then return end

	local mod = _registered_mods[_focused_mod]
	-- Only switch back to the default server if there is no active lobby.
	if not _engaged_mod and mod then
		connect_to_default_server(mod)
	end

	_focused_mod = nil
	_current_view = nil
	_pending_cleanup = nil
	restore_main_menu()
	update_account_button()
end

-- Called by lobby.lua after a lobby fires its 'connected' event.
MPAPI._internal.on_lobby_connected = function(lobby)
	_engaged_mod = lobby.mod_id

	-- A lobby can opt out of the lobby-menu view (e.g. SPDRN practice, which drops
	-- the player straight into a run). Mark it engaged but skip the UI transition.
	if lobby.suppress_lobby_view then
		update_account_button()
		return
	end

	-- Only transition to the lobby view if this mod is currently focused.
	if _focused_mod == lobby.mod_id then
		local mod = _registered_mods[_engaged_mod]
		if mod and mod.lobby_ui then
			_current_view = 'lobby_menu'
			replace_main_menu(mod.lobby_ui)
		end
	end

	update_account_button()
end

-- Called by lobby.lua after a lobby fires its 'disconnected' event.
MPAPI._internal.on_lobby_disconnected = function()
	local was_in_lobby_view = _current_view == 'lobby_menu'
	_engaged_mod = nil
	_pending_cleanup = nil

	-- If disconnecting while in a run (e.g. "Continue in Singleplayer"),
	-- clear focused state so the game returns to the vanilla main menu
	-- when the run ends. Skip update_account_button() to avoid recreating
	-- the UIBox (which is in uibox mode from the main menu) over the game.
	if G.STAGE == G.STAGES.RUN then
		_focused_mod = nil
		_current_view = nil
		return
	end

	if was_in_lobby_view and _focused_mod then
		local mod = _registered_mods[_focused_mod]
		if mod and mod.main_menu_ui then
			_current_view = 'mod_menu'
			replace_main_menu(mod.main_menu_ui)
		end
	end

	update_account_button()
end

-- Rebuilds the current view without animation. Used by set_main_menu_UI
-- when the game engine recreates the main menu (e.g. returning from a run).
-- Returns true if it handled the rebuild, false if the caller should fall
-- back to the original game menu.
MPAPI._internal.rebuild_current_menu = function()
	_pending_cleanup = nil
	if _focused_mod and _current_view == 'lobby_menu' then
		local mod = _registered_mods[_focused_mod]
		if mod and mod.lobby_ui then
			replace_main_menu(mod.lobby_ui)
			return true
		end
	end
	if _focused_mod and _current_view == 'mod_menu' then
		local mod = _registered_mods[_focused_mod]
		if mod and mod.main_menu_ui then
			replace_main_menu(mod.main_menu_ui)
			return true
		end
	end
	return false
end

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

connect_to_active_mod_server = function(mod)
	if mod and mod.server_config then
		MPAPI.disconnect()
		MPAPI.connect(mod.server_config)
	end
end

connect_to_default_server = function(mod)
	if mod and mod.server_config then
		MPAPI.disconnect()
		MPAPI.connect()
	end
end

update_account_button = function()
	if MPAPI.account_button then
		MPAPI.account_button:update()
	end
end

-- Normalises a registered ui value into { build, cleanup }.
-- Accepts either a plain builder function or a { builder, cleanup } pair.
resolve_view = function(ui)
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
replace_main_menu = function(ui)
	local view = resolve_view(ui)

	local delay, on_enter = 0, nil
	if _pending_cleanup and G.MAIN_MENU_UI then
		delay, on_enter = _pending_cleanup(G.MAIN_MENU_UI)
		delay = delay or 0
	end
	_pending_cleanup = view.cleanup

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

restore_main_menu = function()
	if G.MAIN_MENU_UI then
		G.MAIN_MENU_UI:remove()
	end
	MPAPI.set_logo_offset(0, true)
	if _original_set_main_menu_UI then
		_original_set_main_menu_UI()
	end
end

local _original_options = G.FUNCS.options
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
		_original_options(e)
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
