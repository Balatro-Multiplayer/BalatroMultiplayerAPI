-- Shown when reconnecting ran out of time (the server's seat grace period,
-- plus a margin, passed with the socket still down): the server forfeited the
-- seat, so the match is over for this player. One button, and it goes to the
-- main menu, discarding the local run. Same shape as the forfeited notice.
local create_UIBox_connection_lost_notice_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_connection_lost_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_connection_lost_body'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_connection_lost_notice_menu',
						}, nodes = {
							{ n = G.UIT.T, config = { text = localize('k_connection_lost_menu'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						} },
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ no_back = true, no_esc = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_connection_lost_notice_menu = function(e)
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
	-- The give-up can land inside a run, not only on the menu.
	if G.STAGE ~= G.STAGES.MAIN_MENU then
		G.FUNCS.go_to_menu()
	end
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.connection_lost_notice_overlay = MPAPI.ui_element(create_UIBox_connection_lost_notice_overlay)

function MPAPI.show_connection_lost_notice()
	MPAPI._internal.connection_lost_notice_shown = (MPAPI._internal.connection_lost_notice_shown or 0) + 1
	MPAPI.connection_lost_notice_overlay:as_overlay({ no_esc = true })
end
