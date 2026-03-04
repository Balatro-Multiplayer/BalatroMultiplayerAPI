local function create_UIBox_account_overlay()
    local nodes = {}

    -- Header
    nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
        {n=G.UIT.T, config={text = "Multiplayer Account", scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true}}
    }}

    nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05, minh = 0.1}, nodes={}}

    if MPAPI.connection_state.state == "connected" then
        -- Player name
        local player_name = MPAPI.connection_state.steam_name ~= "" and MPAPI.connection_state.steam_name or "Unknown"
        if MPAPI.connection_state.is_temp then
            player_name = player_name .. " (Dev)"
        end
        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05}, nodes={
            {n=G.UIT.T, config={text = "Player: ", scale = 0.38, colour = G.C.UI.TEXT_LIGHT}},
            {n=G.UIT.T, config={text = player_name, scale = 0.38, colour = MPAPI.connection_state.is_temp and G.C.GOLD or G.C.GREEN}},
        }}

        -- Player ID
        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05}, nodes={
            {n=G.UIT.T, config={text = "ID: ", scale = 0.32, colour = G.C.UI.TEXT_LIGHT}},
            {n=G.UIT.T, config={text = MPAPI.connection_state.player_id, scale = 0.32, colour = G.C.UI.TEXT_INACTIVE}},
        }}

        -- Discord link status
        local discord_status = MPAPI.connection_state.discord_name ~= "" and "Linked" or "Not linked"
        local discord_colour = MPAPI.connection_state.discord_name ~= "" and G.C.GREEN or G.C.UI.TEXT_INACTIVE
        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05}, nodes={
            {n=G.UIT.T, config={text = "Discord: ", scale = 0.35, colour = G.C.UI.TEXT_LIGHT}},
            {n=G.UIT.T, config={text = discord_status, scale = 0.35, colour = discord_colour}},
        }}

        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05, minh = 0.15}, nodes={}}

        -- Link Discord button (only if not already linked)
        if MPAPI.connection_state.discord_name == "" then
            nodes[#nodes + 1] = UIBox_button({label = {"Link Discord"}, button = "mpapi_link_discord", minw = 3, minh = 0.6, scale = 0.4, colour = G.C.BLUE})
        end
    else
        -- Disconnected state
        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
            {n=G.UIT.T, config={text = "Status: ", scale = 0.38, colour = G.C.UI.TEXT_LIGHT}},
            {n=G.UIT.T, config={text = MPAPI.connection_state.status_text, scale = 0.38, colour = G.C.RED}},
        }}

        nodes[#nodes + 1] = {n=G.UIT.R, config={align = "cm", padding = 0.05, minh = 0.15}, nodes={}}

        -- Retry button
        if MPAPI.connection_state.state == "disconnected" then
            nodes[#nodes + 1] = UIBox_button({label = {"Retry Connection"}, button = "mpapi_retry_connection", minw = 3, minh = 0.6, scale = 0.4, colour = G.C.RED})
        end
    end

    return create_UIBox_generic_options({contents = nodes})
end

local function create_UIBox_account_button()
    local status_colour = G.C.RED
    if MPAPI.connection_state.state == "connected" then
        status_colour = G.C.GREEN
    elseif MPAPI.connection_state.state == "authenticating" or MPAPI.connection_state.state == "connecting" then
        status_colour = G.C.GOLD
    end

    return {n=G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes={
        {n=G.UIT.R, config={align = "cm", padding = 0.2, r = 0.1, emboss = 0.1, colour = G.C.L_BLACK, hover = true, button = 'mpapi_account_menu'}, nodes={
            {n=G.UIT.R, config={align = "cm"}, nodes={
                {n=G.UIT.T, config={text = "Multiplayer", scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true}}
            }},
            {n=G.UIT.R, config={align = "cm"}, nodes={
                {n=G.UIT.C, config={align = "cm", padding = 0.15, minw = 2, minh = 0.6, maxw = 2.5, r = 0.1, colour = mix_colours(G.C.WHITE, G.C.GREY, 0.2), shadow = true}, nodes={
                    {n=G.UIT.T, config={ref_table = MPAPI.connection_state, ref_value = 'status_text', scale = 0.35, colour = status_colour, shadow = true}}
                }},
            }},
        }},
    }}
end

MPAPI.account_overlay = MPAPI.ui_element(create_UIBox_account_overlay)
MPAPI.account_button = MPAPI.ui_element(create_UIBox_account_button)

G.FUNCS.mpapi_account_menu = function(e)
    MPAPI.account_overlay:as_overlay()
end

G.FUNCS.mpapi_retry_connection = function(e)
    G.FUNCS.exit_overlay_menu()
    MPAPI.disconnect()
    local last_opts = MPAPI.get_last_opts()
    MPAPI.connect(last_opts or {})
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

local _set_main_menu_UI_ref = set_main_menu_UI
function set_main_menu_UI()
    _set_main_menu_UI_ref()

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
