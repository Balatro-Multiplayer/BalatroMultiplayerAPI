local _id_counter = 0

local function next_id()
    _id_counter = _id_counter + 1
    return "mpapi_uel_" .. _id_counter
end

local function find_uie_global(id)
    -- Check overlay first (common case for overlay elements)
    if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true and G.OVERLAY_MENU.get_UIE_by_ID then
        local found = G.OVERLAY_MENU:get_UIE_by_ID(id)
        if found then return found, G.OVERLAY_MENU end
    end
    -- Search all UIBox instances (registered under G.I.UIBOX)
    local uiboxes = G.I and G.I.UIBOX
    if not uiboxes then return nil, nil end
    for i = #uiboxes, 1, -1 do
        local uibox = uiboxes[i]
        if uibox and uibox.get_UIE_by_ID then
            local found = uibox:get_UIE_by_ID(id)
            if found then return found, uibox end
        end
    end
    return nil, nil
end

function MPAPI.ui_element(build_fn)
    local id = next_id()
    local el = {}

    local _mode = nil          -- nil = inline, "uibox", "overlay"
    local _uibox = nil         -- current UIBox (uibox mode)
    local _uibox_config = nil  -- config for UIBox recreation
    local _uibox_on_create = nil -- callback after UIBox (re)creation
    local _cached_uibox = nil  -- cached parent UIBox (inline mode)

    local function build_inline()
        local ok, def = pcall(build_fn)
        local children = (ok and def and def.nodes) or {}
        return {n=G.UIT.C, config={id=id, align="cm", colour=G.C.CLEAR}, nodes=children}
    end

    -- Lazily build the inline node on first access
    setmetatable(el, {__index = function(t, k)
        if k == "node" then
            local node = build_inline()
            rawset(t, "node", node)
            return node
        end
    end})

    -- Shared: find our wrapper by stable ID, swap its children
    local function swap_children_in_place()
        local container, uibox

        if _cached_uibox then
            container = _cached_uibox:get_UIE_by_ID(id)
            if container then
                uibox = _cached_uibox
            else
                _cached_uibox = nil
            end
        end

        if not container then
            container, uibox = find_uie_global(id)
            if uibox then _cached_uibox = uibox end
        end

        if not container or not uibox then return false end

        -- Remove existing children
        remove_all(container.children)
        container.children = {}

        -- Build fresh content and attach new children
        local new_def = build_fn()
        if new_def and new_def.nodes then
            for _, child_def in ipairs(new_def.nodes) do
                uibox:set_parent_child(child_def, container)
            end
        end

        uibox:recalculate()
        return true
    end

    function el:update()
        -- UIBox mode: destroy and recreate with same config
        if _mode == "uibox" then
            if _uibox then
                pcall(function() _uibox:remove() end)
            end
            _uibox = UIBox{definition = build_fn(), config = _uibox_config}
            if _uibox_on_create then _uibox_on_create(_uibox) end
            return _uibox
        end

        -- Overlay and inline mode: swap children in-place via stable ID
        swap_children_in_place()
    end

    function el:as_uibox(config, on_create)
        _mode = "uibox"
        _uibox_config = config
        _uibox_on_create = on_create
        _uibox = UIBox{definition = build_fn(), config = config}
        if _uibox_on_create then _uibox_on_create(_uibox) end
        return _uibox
    end

    function el:as_overlay()
        _mode = "overlay"
        local def = build_fn()
        -- Wrap ROOT children with our stable ID so update() can swap in-place
        if def and def.nodes then
            def = {n=def.n, config=def.config, nodes={
                {n=G.UIT.C, config={id=id, align="cm", colour=G.C.CLEAR}, nodes=def.nodes}
            }}
        end
        G.FUNCS.overlay_menu{definition = def}
    end

    function el:get_uibox()
        return _uibox
    end

    function el:get_id()
        return id
    end

    return el
end

local function resolve_enabled(args)
    if type(args.enabled) == "function" then
        return args.enabled() and true or false
    end
    if args.enabled ~= nil then
        return args.enabled and true or false
    end
    local t = args.enabled_ref_table or {}
    local v = args.enabled_ref_value
    return (v ~= nil and t[v]) and true or false
end

local function walk_nodes(node, visitor)
    if not node then return end
    visitor(node, node.config or {})
    if node.nodes then
        for _, child in ipairs(node.nodes) do
            walk_nodes(child, visitor)
        end
    end
end

local function strip_interactivity(root)
    walk_nodes(root, function(_, config)
        config.button = nil
        config.hover = false
        config.shadow = false
        config.toggle_callback = nil
        config.button_dist = nil
    end)
end

local function gray_text(root)
    walk_nodes(root, function(node, _)
        if node.n == G.UIT.T then
            node.colour = G.C.UI.TEXT_INACTIVE
            node.shadow = false
        end
    end)
end

local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function MPAPI.disableable_button(args)
    return MPAPI.ui_element(function()
        local enabled = resolve_enabled(args)
        local build_args = shallow_copy(args)
        build_args.colour = build_args.colour or G.C.RED
        build_args.text_colour = build_args.text_colour or G.C.UI.TEXT_LIGHT
        build_args.disabled_text = build_args.disabled_text or build_args.label
        if not enabled then
            build_args.label = build_args.disabled_text
        end

        local node = UIBox_button(build_args)
        if not enabled then
            strip_interactivity(node)
            pcall(function()
                node.nodes[1].config.colour = G.C.UI.BACKGROUND_INACTIVE
            end)
            gray_text(node)
        end
        return {n=G.UIT.R, config={align="cm"}, nodes={node}}
    end)
end

function MPAPI.disableable_toggle(args)
    return MPAPI.ui_element(function()
        local enabled = resolve_enabled(args)
        local build_args = shallow_copy(args)

        local node = create_toggle(build_args)
        if not enabled then
            strip_interactivity(node)
            gray_text(node)
        end
        return {n=G.UIT.R, config={align="cm"}, nodes={node}}
    end)
end

function MPAPI.disableable_option_cycle(args)
    return MPAPI.ui_element(function()
        local enabled = resolve_enabled(args)
        local build_args = shallow_copy(args)
        if not enabled then
            build_args.options = { build_args.options[build_args.current_option] }
            build_args.current_option = 1
        end

        local node = create_option_cycle(build_args)
        if not enabled then
            strip_interactivity(node)
            gray_text(node)
        end
        return {n=G.UIT.R, config={align="cm"}, nodes={node}}
    end)
end