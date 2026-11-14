-- In-run roster, opened from ui/lobby_button.lua. Uses lobby_card_grid.lua
-- and card_info_providers.lua; clicking a card opens player_mute_overlay.lua.
local build_lobby_info_overlay_inner
local lobby_info_title
local lobby_info_overlay_inner

-----------------------------
-- STATE
-----------------------------

-- Separate from the pre-match lobby grid; replaced on each open.
local _players_grid = nil

local function ensure_players_grid(lobby)
	if _players_grid then
		return _players_grid
	end
	_players_grid = MPAPI._new_card_grid()
	_players_grid:build_element(lobby)
	return _players_grid
end

-----------------------------
-- UI BUILD FUNCTIONS
-----------------------------

lobby_info_title = function()
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('k_lobby_info_title'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
	} }
end

build_lobby_info_overlay_inner = function()
	local lobby = MPAPI.get_current_lobby()
	local content_nodes
	if not lobby then
		content_nodes = { { n = G.UIT.R, config = { align = 'cm', minh = 2 }, nodes = {
			{ n = G.UIT.T, config = { text = localize('k_lobby_info_no_lobby'), scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} } }
	elseif not G.OVERLAY_MENU then
		-- show_lobby_info_overlay populates this after opening.
		content_nodes = {}
	else
		local grid = ensure_players_grid(lobby)
		content_nodes = { { n = G.UIT.C, config = { align = 'cm' }, nodes = { grid.el.node } } }
	end

	local nodes = { lobby_info_title() }
	for _, node in ipairs(content_nodes) do
		nodes[#nodes + 1] = node
	end

	return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = nodes }
end

local create_UIBox_lobby_info_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 10, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = { lobby_info_overlay_inner.node },
		},
	}
	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- GLOBAL UI ELEMENTS
-----------------------------

lobby_info_overlay_inner = MPAPI.ui_element(build_lobby_info_overlay_inner)
MPAPI._lobby_info_overlay_el = MPAPI.ui_element(create_UIBox_lobby_info_overlay)
-- Test hook for refresh counts.
MPAPI._lobby_info_overlay_inner_el = lobby_info_overlay_inner

-- Overlay teardown removes cards but doesn't unregister the grid.
function MPAPI.show_lobby_info_overlay()
	local lobby = MPAPI.get_current_lobby()
	if not lobby then
		return
	end
	if _players_grid then
		_players_grid:destroy()
		_players_grid = nil
	end
	MPAPI._lobby_info_overlay_el:as_overlay()
	-- Without an overlay, Card:set_ability marks avatars in used_jokers,
	-- excluding them from normal shop rolls.
	lobby_info_overlay_inner:update()
end
