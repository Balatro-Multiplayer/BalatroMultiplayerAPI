-- Shown when the server's launcher-integrity anti-cheat check fails (see
-- networking/connection.lua's handling of a 'challenge'/type='failed'
-- notification, and launcher-integrity.service.ts's failIntegrity() on the
-- server side). This does NOT disconnect the client - it only costs Ranked
-- eligibility (MPAPI.is_launcher_verified()) - so the notice is purely
-- informational, not an explanation for a kick. Body text comes from the
-- server (see below) rather than a fixed localized string, since it's the
-- server's own reason to explain. Twin of ui/kicked_notice_overlay.lua's
-- small modal pattern.
local function build_anticheat_failed_uibox(message)
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_anticheat_failed_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = message, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_anticheat_failed_dismiss',
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

G.FUNCS.mpapi_anticheat_failed_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- GLOBAL FUNCTION
-----------------------------

-- message: the server's own explanation string (see launcher-integrity.service.ts's
-- failIntegrity()) - falls back to a generic explanation if somehow absent,
-- rather than showing a blank body.
function MPAPI.show_anticheat_failed_notice(message)
	local overlay = MPAPI.ui_element(function()
		return build_anticheat_failed_uibox(message or "Your launcher could not be verified. You'll need to pass this check to queue for Ranked.")
	end)
	overlay:as_overlay()
end
