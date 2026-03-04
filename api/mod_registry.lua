local _registered_mods = {}  -- keyed by mod ID → mod entry
local _mod_order = {}        -- ordered list of third-party mod IDs
local _active_mod = nil      -- ID of currently active mod, or nil
local _default_server_config = nil
local _original_set_main_menu_UI = nil  -- captured before any hooks

local _official_mods = {
    { id = "MultiplayerPvP",          name = "PvP",       colour = G.C.RED,   download_url = "https://github.com/V-rtualized/MultiplayerPvP" },
    { id = "MultiplayerSpeedrunning", name = "Speedrun",  colour = G.C.GREEN, download_url = "https://github.com/V-rtualized/MultiplayerSpeedrunning" },
    { id = "MultiplayerCoop",         name = "Co-op",     colour = G.C.BLUE,  download_url = "https://github.com/V-rtualized/MultiplayerCoop" },
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

function MPAPI.register_mod(opts)
    if not opts.id then
        MPAPI.sendWarnMessage("register_mod: missing id")
        return
    end
    if not opts.main_menu_ui then
        MPAPI.sendWarnMessage("register_mod: missing main_menu_ui for " .. opts.id)
        return
    end

    local existing = _registered_mods[opts.id]
    if existing and existing.is_official then
        -- Merge into official entry
        existing.main_menu_ui = opts.main_menu_ui
        existing.server_config = opts.server_config
        if opts.name then existing.name = opts.name end
        if opts.colour then existing.colour = opts.colour end
    else
        -- New third-party mod
        _registered_mods[opts.id] = {
            id = opts.id,
            name = opts.name or opts.id,
            colour = opts.colour or G.C.PURPLE,
            server_config = opts.server_config,
            main_menu_ui = opts.main_menu_ui,
            download_url = opts.download_url,
            is_official = false,
        }
        _mod_order[#_mod_order + 1] = opts.id
    end

    -- If we're on the main menu, refresh the account panel
    if MPAPI.account_button then
        MPAPI.account_button:update()
    end
end

function MPAPI.activate_mod(id)
    local mod = _registered_mods[id]
    if not mod then
        MPAPI.sendWarnMessage("activate_mod: unknown mod " .. tostring(id))
        return
    end

    -- If mod isn't registered (official but not installed), open download page
    if not mod.main_menu_ui then
        if mod.download_url then
            love.system.openURL(mod.download_url)
        end
        return
    end

    _active_mod = id

    -- Handle server switching
    if mod.server_config then
        -- Capture default config before switching
        if not _default_server_config then
            _default_server_config = MPAPI.get_last_opts() or {}
        end
        MPAPI.disconnect()
        MPAPI.connect(mod.server_config)
    end

    -- Replace main menu
    if G.MAIN_MENU_UI then
        G.MAIN_MENU_UI:remove()
    end
    G.MAIN_MENU_UI = UIBox{
        definition = mod.main_menu_ui(),
        config = {align = "bmi", offset = {x = 0, y = 10}, major = G.ROOM_ATTACH, bond = 'Weak'},
    }
    G.MAIN_MENU_UI.alignment.offset.y = 0
    G.MAIN_MENU_UI:align_to_major()

    -- Refresh account panel to show back button
    if MPAPI.account_button then
        MPAPI.account_button:update()
    end
end

function MPAPI.deactivate_mod()
    if not _active_mod then return end

    local mod = _registered_mods[_active_mod]
    _active_mod = nil

    -- Reconnect to default server if mod had a custom one
    if mod and mod.server_config then
        MPAPI.disconnect()
        if _default_server_config then
            MPAPI.connect(_default_server_config)
        end
    end

    -- Restore vanilla main menu
    if G.MAIN_MENU_UI then
        G.MAIN_MENU_UI:remove()
    end
    if _original_set_main_menu_UI then
        _original_set_main_menu_UI()
    end

    -- Refresh account panel to show mod buttons
    if MPAPI.account_button then
        MPAPI.account_button:update()
    end
end

function MPAPI.get_active_mod()
    return _active_mod
end

function MPAPI.get_registered_mods()
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

-- Store the original set_main_menu_UI before any hooks
-- This is called from the set_main_menu_UI hook in account.lua
function MPAPI._capture_original_set_main_menu_UI(fn)
    _original_set_main_menu_UI = fn
end
