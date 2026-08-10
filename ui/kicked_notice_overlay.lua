-- Shown to a player after the host kicks them from a lobby (see
-- api/lobby/events.lua's on_player_kicked), once the client has already been
-- returned to the menu. There's no existing player-facing toast in MPAPI
-- (chat's addMessage only writes to the debug console), so this is a small
-- modal twin of ui/chat_enable_overlay.lua.
local create_UIBox_kicked_notice_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_kicked_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_player_kicked_you'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_kicked_notice_dismiss',
						}, nodes = {
							{ n = G.UIT.T, config = { text = localize('k_ok'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						} },
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_kicked_notice_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.kicked_notice_overlay = MPAPI.ui_element(create_UIBox_kicked_notice_overlay)

function MPAPI.show_kicked_notice()
	MPAPI.kicked_notice_overlay:as_overlay()
end
