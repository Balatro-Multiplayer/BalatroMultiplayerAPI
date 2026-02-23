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
