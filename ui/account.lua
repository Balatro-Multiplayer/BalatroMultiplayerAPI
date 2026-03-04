-- Build a stats-style info row (label on left, value on right with dark background)
local function account_info_row(label, value_nodes, label_w, value_w)
    label_w = label_w or 3
    value_w = value_w or 4
    return {n=G.UIT.R, config={align = "cm", padding = 0.05, r = 0.1, colour = darken(G.C.JOKER_GREY, 0.1), emboss = 0.05}, nodes={
        {n=G.UIT.C, config={align = "cm", padding = 0.05, minw = label_w, maxw = label_w}, nodes={
            {n=G.UIT.T, config={text = label, scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true}},
        }},
        {n=G.UIT.C, config={align = "cl", minh = 0.7, r = 0.1, minw = value_w, colour = G.C.BLACK, emboss = 0.05}, nodes={
            {n=G.UIT.C, config={align = "cm", padding = 0.05, r = 0.1, minw = value_w, maxw = value_w}, nodes=value_nodes},
        }},
    }}
end

local function create_UIBox_account_overlay()
    if MPAPI.connection_state.state ~= "connected" then return G.FUNCS.exit_overlay_menu() end

    local cs = MPAPI.connection_state
    local label_w, value_w = 3.5, 4.5

    -- Username
    local player_name = cs.steam_name ~= "" and cs.steam_name or "Unknown"
    local name_colour = G.C.GREEN
    if cs.is_temp then
        player_name = player_name .. " (Dev)"
        name_colour = G.C.GOLD
    end

    -- Discord
    local discord_linked = cs.discord_name ~= ""
    local discord_value = discord_linked and cs.discord_name or "Not Linked"
    local discord_colour = discord_linked and G.C.GREEN or G.C.UI.TEXT_INACTIVE

    -- Display name preference cycle (disabled when discord not linked)
    local pref_options = {"Steam", "Discord"}
    local current_pref = cs.display_name_pref or 1
    if not discord_linked then current_pref = 1 end

    -- Info rows: ID, Username, Discord Username
    local info_rows = {
        account_info_row("ID", {
            {n=G.UIT.T, config={text = cs.player_id, scale = 0.35, colour = G.C.UI.TEXT_INACTIVE}},
        }, label_w, value_w),
        account_info_row("Username", {
            {n=G.UIT.O, config={object = DynaText({string = {player_name}, colours = {name_colour}, shadow = true, float = true, scale = 0.45})}},
        }, label_w, value_w),
        account_info_row("Discord", {
            {n=G.UIT.O, config={object = DynaText({string = {discord_value}, colours = {discord_colour}, shadow = true, float = true, scale = 0.45})}},
        }, label_w, value_w),
    }

    local contents = {
        {n=G.UIT.C, config={align = "cm", minw = 3, padding = 0.2, r = 0.1, colour = G.C.CLEAR}, nodes={
            -- Title
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
                {n=G.UIT.T, config={text = "Multiplayer Account", scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true}},
            }},
            -- Info rows
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes=info_rows},
            -- Display name preference cycle (disabled when discord not linked)
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
                MPAPI.disableable_option_cycle({
                    label = "Display Name",
                    options = pref_options,
                    current_option = current_pref,
                    opt_callback = 'mpapi_change_display_pref',
                    scale = 0.8,
                    colour = MPAPI.C.MP_EDITION,
                    focus_args = {nav = 'wide'},
                    enabled = discord_linked,
                }).node,
                not discord_linked and UIBox_button({label = {"Link Discord"}, button = "mpapi_link_discord", minh = 0.7, scale = 0.4, colour = G.C.BLUE, focus_args = {nav = 'wide'}}) or nil,
                }},
            }},
    }

    return create_UIBox_generic_options({back_func = 'exit_overlay_menu', snap_back = true, contents = contents})
end

-- Build a single mod button row with optional subtext
local function build_mod_button(mod, inner_width)
    local is_installed = mod.main_menu_ui ~= nil
    local subtext = not is_installed and localize('b_open_download_page') or nil
    local button_ref = { mod_id = mod.id }

    local button_nodes = {
        {n=G.UIT.T, config={text = mod.name, scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true}},
    }
    if subtext then
        button_nodes[#button_nodes + 1] = {n=G.UIT.T, config={text = subtext, scale = 0.25, colour = mix_colours(G.C.UI.TEXT_LIGHT, G.C.UI.TEXT_DARK, 0.8)}}
    end

    local rows = {}
    for _, node in ipairs(button_nodes) do
        rows[#rows + 1] = {n=G.UIT.R, config={align = "cm"}, nodes={node}}
    end

    return {n=G.UIT.R, config={align = "cm", padding = 0.03}, nodes={
        {n=G.UIT.C, config={
            align = "cm", padding = 0.08, minw = inner_width, maxw = inner_width, minh = 0.6,
            r = 0.1, hover = true, shadow = true,
            colour = (not is_installed and G.C.UI.BACKGROUND_INACTIVE) or mod.colour or G.C.PURPLE,
            button = "mpapi_mod_button",
            ref_table = button_ref, ref_value = "mod_id",
        }, nodes=rows},
    }}
end

local function create_UIBox_account_button()
    local status_colour = G.C.RED
    if MPAPI.connection_state.state == "connected" then
        status_colour = G.C.WHITE
    elseif MPAPI.connection_state.state == "authenticating" or MPAPI.connection_state.state == "connecting" then
        status_colour = G.C.GOLD
    end

    local outer_width = 2.3
    local inner_width = 2.2

    local panel_nodes = {}

    -- Title
    panel_nodes[#panel_nodes + 1] = {n=G.UIT.R, config={align = "cm"}, nodes={
        {n=G.UIT.T, config={text = localize('k_multiplayer'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true}}
    }}

    -- Account button
    panel_nodes[#panel_nodes + 1] = {n=G.UIT.R, config={align = "cm"}, nodes={
        {n=G.UIT.C, config={align = "cm", padding = 0.1, minw = inner_width, minh = 0.8, maxw = inner_width, r = 0.1, hover = true, colour = mix_colours(G.C.WHITE, G.C.GREY, 0.2), button = 'mpapi_account_button', shadow = true}, nodes={
            {n=G.UIT.T, config={ref_table = MPAPI.connection_state, ref_value = 'display_name', scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true}}
        }},
    }}

    if MPAPI.get_active_mod() then
        -- Mod active: show back button
        panel_nodes[#panel_nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.03}, nodes={
            {n=G.UIT.C, config={
                align = "cm", padding = 0.08, minw = inner_width, maxw = inner_width, minh = 0.6,
                r = 0.1, hover = true, shadow = true,
                colour = G.C.ORANGE,
                button = "mpapi_back_button",
            }, nodes={
                {n=G.UIT.R, config={align = "cm"}, nodes={
                    {n=G.UIT.T, config={text = localize('b_back'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true}},
                }},
            }},
        }}
    else
        -- Normal mode: show mod buttons vertically
        local mods = MPAPI.get_registered_mods()
        for _, mod in ipairs(mods) do
            panel_nodes[#panel_nodes + 1] = build_mod_button(mod, inner_width)
        end
    end

    -- Connection status
    panel_nodes[#panel_nodes + 1] = {n=G.UIT.R, config={align = "cm"}, nodes={
        {n=G.UIT.T, config={ref_table = MPAPI.connection_state, ref_value = 'status_text', scale = 0.3, colour = status_colour, shadow = true}}
    }}

    return {n=G.UIT.ROOT, config = {align = "cm", minw = outer_width, maxw = outer_width, colour = G.C.CLEAR}, nodes={
        {n=G.UIT.R, config={align = "cm", padding = 0.1, r = 0.1, emboss = 0.1, colour = MPAPI.C.MP_EDITION, minw = outer_width, maxw = outer_width}, nodes=panel_nodes}
    }}
end

MPAPI.account_overlay = MPAPI.ui_element(create_UIBox_account_overlay)
MPAPI.account_button = MPAPI.ui_element(create_UIBox_account_button)

-- Account button: open overlay when connected, retry when disconnected
G.FUNCS.mpapi_account_button = function(e)
    if MPAPI.connection_state.state == "connected" then
        MPAPI.account_overlay:as_overlay()
    end
    if MPAPI.connection_state.state == "disconnected" then
        MPAPI.disconnect()
        local last_opts = MPAPI.get_last_opts()
        MPAPI.connect(last_opts or {})
    end
end

-- Mod button: activate mod or open download page
G.FUNCS.mpapi_mod_button = function(e)
    local mod_id = e.config and e.config.ref_table and e.config.ref_table.mod_id
    if mod_id then
        MPAPI.activate_mod(mod_id)
    end
end

-- Back button: deactivate current mod, return to normal menu
G.FUNCS.mpapi_back_button = function(e)
    MPAPI.deactivate_mod()
end

G.FUNCS.mpapi_change_display_pref = function(args)
    local cs = MPAPI.connection_state
    cs.display_name_pref = args.to_key
    MPAPI.update_display_name()
    if MPAPI.account_button then
        MPAPI.account_button:update()
    end
end

G.FUNCS.mpapi_link_discord = function(e)
    MPAPI.get_discord_link_url(function(err, data)
        if err then
            MPAPI.sendWarnMessage("Discord link error: " .. tostring(err))
            return
        end
        if data and data.url then
            MPAPI.sendDebugMessage("Opening Discord link URL")
            love.system.openURL(data.url)
        end
    end)
end

-- Hook set_main_menu_UI: add account panel, handle active mod menu replacement
local _set_main_menu_UI_ref = set_main_menu_UI
MPAPI._capture_original_set_main_menu_UI(_set_main_menu_UI_ref)

function set_main_menu_UI()
    local active = MPAPI.get_active_mod()

    if active then
        -- Active mod: replace main menu with mod's UI
        local mods = MPAPI.get_registered_mods()
        local mod
        for _, m in ipairs(mods) do
            if m.id == active then mod = m; break end
        end
        if mod and mod.main_menu_ui then
            if G.MAIN_MENU_UI then G.MAIN_MENU_UI:remove() end
            G.MAIN_MENU_UI = UIBox{
                definition = mod.main_menu_ui(),
                config = {align = "bmi", offset = {x = 0, y = 10}, major = G.ROOM_ATTACH, bond = 'Weak'},
            }
            G.MAIN_MENU_UI.alignment.offset.y = 0
            G.MAIN_MENU_UI:align_to_major()
        else
            _set_main_menu_UI_ref()
        end
    else
        _set_main_menu_UI_ref()
    end

    -- Always add account panel
    G.E_MANAGER:add_event(Event({
        blockable = false,
        blocking = false,
        func = function()
            MPAPI.account_button:as_uibox(
                {align="tli", offset = {x=-10,y=0}, major = G.ROOM_ATTACH, bond = 'Weak'},
                function(uibox)
                    uibox.alignment.offset.x = 0
                    uibox:align_to_major()
                end
            )
            return true
        end,
    }))
end
