-- Forward declarations for helper functions
local next_id
local find_uie_global
local resolve_enabled
local strip_interactivity
local gray_text

-----------------------------
-- STATE VARIABLES
-----------------------------

local _id_counter = 0

-----------------------------
-- API FUNCTIONS
-----------------------------

-- Creates a reactive UI element that can rebuild itself in-place.
--
-- build_fn: a function that returns a UI definition table ({ n = ..., nodes = ... }).
--           Called once on creation, and again each time el:update() is invoked.
--
-- The returned element supports three display modes:
--
--   Inline (default):
--     Access el.node to get a UI definition you can embed in another layout.
--     The node is lazily built on first access. Calling el:update() finds the
--     rendered element by its stable ID and swaps its children in-place.
--
--   UIBox (el:as_uibox(config, on_create)):
--     Creates a standalone UIBox. Calling el:update() destroys and recreates
--     the entire UIBox with the same config. on_create is called after each
--     creation with the new UIBox instance.
--
--   Overlay (el:as_overlay()):
--     Opens build_fn's output as an overlay menu. Calling el:update() swaps
--     children in-place (same as inline mode).
--
-- Methods:
--   el:update()                    -- Rebuild the element in its current mode
--   el:as_uibox(config, on_create) -- Switch to UIBox mode and create it
--   el:as_overlay()                -- Open as overlay menu
--   el:get_uibox()                -- Returns the current UIBox (uibox mode only)
--   el:get_id()                   -- Returns the stable ID string
MPAPI.ui_element = function(build_fn)
	local id = next_id()
	local el = {}

	local _mode = nil
	local _uibox = nil
	local _uibox_config = nil
	local _uibox_on_create = nil
	local _cached_uibox = nil

	local function build_inline()
		local ok, def = pcall(build_fn)
		local children = (ok and def and def.nodes) or {}
		return { n = G.UIT.C, config = { id = id, align = 'cm', colour = G.C.CLEAR }, nodes = children }
	end

	-- Build a fresh inline node on every access. No caching: the node table
	-- is consumed by UIBox on render, so reusing a stale reference after the
	-- enclosing UIBox has been destroyed (e.g. returning to game menu from a
	-- lobby view and re-entering) would hand dead nodes to the new UIBox.
	setmetatable(el, {
		__index = function(t, k)
			if k == 'node' then
				return build_inline()
			end
		end,
	})

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
			if uibox then
				_cached_uibox = uibox
			end
		end

		if not container or not uibox then
			return false
		end

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
		-- Destroy and recreate with same config
		if _mode == 'uibox' then
			if _uibox then
				local ok, err = pcall(function()
					_uibox:remove()
				end)
				if not ok then
					MPAPI.sendWarnMessage('[ui_element:' .. id .. '] remove() failed: ' .. tostring(err) .. ' | UIBOX count: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
				end
			end
			_uibox = UIBox({ definition = build_fn(), config = _uibox_config })
			MPAPI.sendDebugMessage('[ui_element:' .. id .. '] update() recreated UIBox | UIBOX count after: ' .. tostring(G.I and G.I.UIBOX and #G.I.UIBOX or '?'))
			if _uibox_on_create then
				_uibox_on_create(_uibox)
			end
			return _uibox
		end

		-- Swap children in-place via stable ID
		swap_children_in_place()
	end

	function el:as_uibox(config, on_create)
		if _uibox then
			pcall(function() _uibox:remove() end)
		end
		_mode = 'uibox'
		_uibox_config = config
		_uibox_on_create = on_create
		_uibox = UIBox({ definition = build_fn(), config = config })
		if _uibox_on_create then
			_uibox_on_create(_uibox)
		end
		return _uibox
	end

	function el:as_overlay()
		_mode = 'overlay'
		local def = build_fn()
		-- Wrap ROOT children with our stable ID so update() can swap in-place
		if def and def.nodes then
			def = { n = def.n, config = def.config, nodes = {
				{ n = G.UIT.C, config = { id = id, align = 'cm', colour = G.C.CLEAR }, nodes = def.nodes },
			} }
		end
		G.FUNCS.overlay_menu({ definition = def })
	end

	function el:get_uibox()
		return _uibox
	end

	function el:get_id()
		return id
	end

	return el
end

MPAPI.disableable_button = function(args)
	local build_fn = function()
		local enabled = resolve_enabled(args)
		local build_args = MPAPI.shallow_copy(args)
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
		return { n = G.UIT.R, config = { align = 'cm' }, nodes = { node } }
	end

	return MPAPI.ui_element(build_fn)
end

MPAPI.disableable_toggle = function(args)
	local build_fn = function()
		local enabled = resolve_enabled(args)
		local build_args = MPAPI.shallow_copy(args)

		local node = create_toggle(build_args)
		if not enabled then
			strip_interactivity(node)
			gray_text(node)
		end
		return { n = G.UIT.R, config = { align = 'cm' }, nodes = { node } }
	end

	return MPAPI.ui_element(build_fn)
end

MPAPI.disableable_option_cycle = function(args)
	local build_fn = function()
		local enabled = resolve_enabled(args)
		local build_args = MPAPI.shallow_copy(args)
		if not enabled then
			build_args.options = { build_args.options[build_args.current_option] }
			build_args.current_option = 1
		end

		local node = create_option_cycle(build_args)
		if not enabled then
			strip_interactivity(node)
			gray_text(node)
		end
		return { n = G.UIT.R, config = { align = 'cm' }, nodes = { node } }
	end

	return MPAPI.ui_element(build_fn)
end

-----------------------------
-- HELPER FUNCTIONS
-----------------------------

next_id = function()
	_id_counter = _id_counter + 1
	return 'mpapi_uel_' .. _id_counter
end

find_uie_global = function(id)
	-- Check overlay first
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true and G.OVERLAY_MENU.get_UIE_by_ID then
		local found = G.OVERLAY_MENU:get_UIE_by_ID(id)
		if found then
			return found, G.OVERLAY_MENU
		end
	end

	-- Search all UIBox instances (registered under G.I.UIBOX)
	local uiboxes = G.I and G.I.UIBOX
	if not uiboxes then
		return nil, nil
	end
	for i = #uiboxes, 1, -1 do
		local uibox = uiboxes[i]
		if uibox and uibox.get_UIE_by_ID then
			local found = uibox:get_UIE_by_ID(id)
			if found then
				return found, uibox
			end
		end
	end
	return nil, nil
end

resolve_enabled = function(args)
	if type(args.enabled) == 'function' then
		return args.enabled() and true or false
	end
	if args.enabled ~= nil then
		return args.enabled and true or false
	end
	local t = args.enabled_ref_table or {}
	local v = args.enabled_ref_value
	return (v ~= nil and t[v]) and true or false
end

strip_interactivity = function(root)
	MPAPI.walk_nodes(root, function(_, config)
		config.button = nil
		config.hover = false
		config.shadow = false
		config.toggle_callback = nil
		config.button_dist = nil
	end)
end

gray_text = function(root)
	MPAPI.walk_nodes(root, function(node, _)
		if node.n == G.UIT.T then
			node.colour = G.C.UI.TEXT_INACTIVE
			node.shadow = false
		end
	end)
end
