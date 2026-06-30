-- Registered-mod records and their accessors. The shared state table is the single
-- source of truth for mod records, focus/engage ids, and the current view; every file
-- in this folder reaches it through MPAPI._internal.mod_registry so load order is irrelevant.
MPAPI._internal.mod_registry = MPAPI._internal.mod_registry or {}
local state = MPAPI._internal.mod_registry
state.registered_mods = state.registered_mods or {}
state.mod_order = state.mod_order or {}

-- Official (first-party) mods. `coming_soon = true` makes an *uninstalled* official
-- mod display "Coming Soon" in the menu instead of a download-page link, and stops
-- its button from opening the download URL. Flip it to false (or remove it) once the
-- mod is published. Installed mods (the player has the folder) ignore this flag.
state.official_mods = state.official_mods or {
	{ id = 'MultiplayerPvP', name = 'PvP', colour = G.C.RED, download_url = 'https://github.com/V-rtualized/MultiplayerPvP', coming_soon = true },
	{ id = 'MultiplayerSPDRN', name = 'Speedrun', colour = G.C.GREEN, download_url = 'https://github.com/V-rtualized/MultiplayerSpeedrunning' },
	{ id = 'MultiplayerCoop', name = 'Co-op', colour = G.C.BLUE, download_url = 'https://github.com/V-rtualized/MultiplayerCoop', coming_soon = true },
}

for _, official in ipairs(state.official_mods) do
	state.registered_mods[official.id] = state.registered_mods[official.id] or {
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

MPAPI.register_mod = function(opts)
	if not opts.id then
		MPAPI.sendWarnMessage('register_mod: missing id')
		return
	end
	if not opts.main_menu_ui then
		MPAPI.sendWarnMessage('register_mod: missing main_menu_ui for ' .. opts.id)
		return
	end

	local existing = state.registered_mods[opts.id]
	if existing and existing.is_official then
		existing.main_menu_ui = opts.main_menu_ui
		existing.lobby_ui = opts.lobby_ui
		existing.server_config = opts.server_config
		existing.prevent_pause = opts.prevent_pause or false
		existing.options_builder = opts.options_builder or nil
		existing.title = opts.title or nil
		if opts.name then existing.name = opts.name end
		if opts.colour then existing.colour = opts.colour end
	else
		state.registered_mods[opts.id] = {
			id = opts.id,
			name = opts.name or opts.id,
			colour = opts.colour or G.C.PURPLE,
			server_config = opts.server_config,
			main_menu_ui = opts.main_menu_ui,
			lobby_ui = opts.lobby_ui,
			download_url = opts.download_url,
			prevent_pause = opts.prevent_pause or false,
			options_builder = opts.options_builder or nil,
			title = opts.title or nil,
			is_official = false,
		}
		state.mod_order[#state.mod_order + 1] = opts.id
	end

	MPAPI._internal.mod_registry.update_account_button()
end

-- Returns the engaged mod id (has an active lobby). This is what mods
-- should check inside hooked game functions to gate their logic.
MPAPI.get_active_mod = function()
	return state.engaged_mod
end

-- Convenience check for mods hooking game functions.
MPAPI.is_active = function(mod_id)
	return state.engaged_mod == mod_id
end

-- Returns the focused mod id (whose menu is currently shown).
MPAPI.get_focused_mod = function()
	return state.focused_mod
end

-- Returns the focused mod's custom title config ({ base, extra }), or nil. Drives the
-- title-logo swap in api/title.lua.
MPAPI._internal.get_active_title = function()
	local mod = state.focused_mod and state.registered_mods[state.focused_mod]
	return mod and mod.title or nil
end

MPAPI.get_active_mod_data = function()
	if not state.engaged_mod then return end
	return state.registered_mods[state.engaged_mod]
end

MPAPI.get_registered_mods = function()
	local result = {}
	for _, official in ipairs(state.official_mods) do
		result[#result + 1] = state.registered_mods[official.id]
	end
	for _, id in ipairs(state.mod_order) do
		result[#result + 1] = state.registered_mods[id]
	end
	return result
end
