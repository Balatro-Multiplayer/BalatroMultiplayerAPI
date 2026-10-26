-- Shown when the server refuses a rejoin because the grace period already
-- forfeited the player's seat (nakama/src/lobby/state.ts, FORFEITED_SEAT):
-- the match is over for them. One button, and it goes to the main menu.
local FORFEITED_TEXT = 'You forfeited this match'

-- Whether a match_join error message is the server's forfeited-seat refusal.
-- Pure.
function MPAPI.is_forfeited_refusal(message)
	return type(message) == 'string' and message:find(FORFEITED_TEXT, 1, true) ~= nil
end

local create_UIBox_forfeited_notice_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_forfeited_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_forfeited_body'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_forfeited_notice_menu',
						}, nodes = {
							{ n = G.UIT.T, config = { text = localize('k_forfeited_menu'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
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

G.FUNCS.mpapi_forfeited_notice_menu = function(e)
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
	-- The refusal can land inside a replayed run, not only on the menu.
	if G.STAGE ~= G.STAGES.MAIN_MENU then
		G.FUNCS.go_to_menu()
	end
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.forfeited_notice_overlay = MPAPI.ui_element(create_UIBox_forfeited_notice_overlay)

function MPAPI.show_forfeited_notice()
	MPAPI._internal.forfeited_notice_shown = (MPAPI._internal.forfeited_notice_shown or 0) + 1
	MPAPI.forfeited_notice_overlay:as_overlay({ no_esc = true })
end
