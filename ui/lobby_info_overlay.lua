-- Default MPAPI-provided "Lobby Info" overlay: just the card grid (identical
-- in style to the live lobby roster, via ui/lobby_card_grid.lua, with per-mod
-- customizable hover info via api/card_info_providers.lua). Clicking a card
-- opens ui/player_mute_overlay.lua's Actions/Mods tabbed overlay for that
-- player. Opened via the in-run pause menu row (api/pause_menu.lua's
-- MPAPI.pause_menu_extra_rows()) -- there is no pre-match lobby entry point,
-- Lobby Info is an in-run-only feature.
local build_lobby_info_overlay_inner
local lobby_info_title
local lobby_info_overlay_inner

-----------------------------
-- STATE
-----------------------------

-- The overlay's own card grid instance, per-overlay-session (created the
-- first time the overlay is opened, torn down on the next open). Kept
-- independent of the live lobby's own grid instance (ui/lobby.lua) per D3 --
-- closing this overlay must never disturb the live lobby's card state.
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
-- Exposed for testability (ClaudeControl suites spy on :update() call counts).
MPAPI._lobby_info_overlay_inner_el = lobby_info_overlay_inner

-- Single entry point (called from the in-run pause menu row). No-ops without
-- a current lobby. Destroys any grid left over from a previous open before
-- opening -- the overlay's own grid instance would otherwise leak into
-- MPAPI._active_card_grids indefinitely, since nothing in vanilla's overlay
-- teardown knows to call grid:destroy() for us.
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
end
