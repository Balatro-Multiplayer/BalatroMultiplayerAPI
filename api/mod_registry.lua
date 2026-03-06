-- Forward declarations for helper functions
local connect_to_active_mod_server
local connect_to_default_server
local update_account_button
local replace_main_menu
local restore_main_menu

-----------------------------
-- STATE VARIABLES
-----------------------------

local _registered_mods = {}
local _mod_order = {}
local _active_mod = nil
local _default_server_config = nil
local _original_set_main_menu_UI = set_main_menu_UI

local _official_mods = {
	{ id = 'MultiplayerPvP', name = 'PvP', colour = G.C.RED, download_url = 'https://github.com/V-rtualized/MultiplayerPvP' },
	{ id = 'MultiplayerSpeedrunning', name = 'Speedrun', colour = G.C.GREEN, download_url = 'https://github.com/V-rtualized/MultiplayerSpeedrunning' },
	{ id = 'MultiplayerCoop', name = 'Co-op', colour = G.C.BLUE, download_url = 'https://github.com/V-rtualized/MultiplayerCoop' },
}

for _, official in ipairs(_official_mods) do
	_registered_mods[official.id] = {
		id = official.id,
		name = official.name,
		colour = official.colour,
		download_url = official.download_url,
		server_config = nil,
		main_menu_ui = nil,
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

	local hide_logo = opts.hide_logo == true

	local existing = _registered_mods[opts.id]
	if existing and existing.is_official then
		existing.main_menu_ui = opts.main_menu_ui
		existing.server_config = opts.server_config
		existing.hide_logo = hide_logo
		if opts.name then
			existing.name = opts.name
		end
		if opts.colour then
			existing.colour = opts.colour
		end
	else
		_registered_mods[opts.id] = {
			id = opts.id,
			name = opts.name or opts.id,
			colour = opts.colour or G.C.PURPLE,
			server_config = opts.server_config,
			main_menu_ui = opts.main_menu_ui,
			download_url = opts.download_url,
			hide_logo = hide_logo,
			is_official = false,
		}
		_mod_order[#_mod_order + 1] = opts.id
	end

	update_account_button()
end

MPAPI.get_active_mod = function()
	return _active_mod
end

MPAPI.get_active_mod_data = function()
	if not _active_mod then
		return
	end
	return _registered_mods[_active_mod]
end

MPAPI.get_registered_mods = function()
	local result = {}
	-- Official mods first, in order
	for _, official in ipairs(_official_mods) do
		result[#result + 1] = _registered_mods[official.id]
	end
	-- Third-party mods in registration order
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
		if mod.download_url then
			love.system.openURL(mod.download_url)
		end
		return
	end

	connect_to_active_mod_server(mod)

	_active_mod = id

	replace_main_menu(mod.main_menu_ui, mod.hide_logo)
	update_account_button()
end

MPAPI._internal.deactivate_mod = function()
	if not _active_mod then
		return
	end

	connect_to_default_server(_registered_mods[_active_mod])

	_active_mod = nil

	restore_main_menu()
	update_account_button()
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

replace_main_menu = function(build_fn, hide_logo)
	if G.MAIN_MENU_UI then
		G.MAIN_MENU_UI:remove()
	end
	if G.PROFILE_BUTTON then
		G.PROFILE_BUTTON:remove()
		G.PROFILE_BUTTON = nil
	end
	if hide_logo then
		if G.SPLASH_LOGO then
			G.SPLASH_LOGO.states.visible = false
		end
		if G.title_top then
			G.title_top.states.visible = false
			for _, card in ipairs(G.title_top.cards or {}) do
				card.states.visible = false
			end
		end
	end
	G.MAIN_MENU_UI = UIBox({
		definition = build_fn(),
		config = { align = 'bmi', offset = { x = 0, y = 10 }, major = G.ROOM_ATTACH, bond = 'Weak' },
	})
	G.MAIN_MENU_UI.alignment.offset.y = 0
	G.MAIN_MENU_UI:align_to_major()
end

MPAPI._internal.replace_main_menu = function(build_fn, hide_logo)
	replace_main_menu(build_fn, hide_logo)
end

restore_main_menu = function()
	if G.MAIN_MENU_UI then
		G.MAIN_MENU_UI:remove()
	end
	if G.SPLASH_LOGO then
		G.SPLASH_LOGO.states.visible = true
	end
	if G.title_top then
		G.title_top.states.visible = true
		for _, card in ipairs(G.title_top.cards or {}) do
			card.states.visible = true
		end
	end
	if _original_set_main_menu_UI then
		_original_set_main_menu_UI()
	end
end
