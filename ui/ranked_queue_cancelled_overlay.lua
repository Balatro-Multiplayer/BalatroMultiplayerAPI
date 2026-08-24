-- Shown when a post-queue-join ranked_readiness challenge (see
-- anticheat/launcher_channel.lua, api/matchmaking/dispatch.lua's
-- on_queue_cancelled) gets the player dequeued for being out of date. Same
-- small modal shape as ui/kicked_notice_overlay.lua - shown centrally here
-- (MPAPI already owns the matchmaking dispatch layer both PvP and SPDRN sit
-- on top of) rather than duplicated into each ranked-queueing mod's own
-- handle:on("error", ...) handler.
local _state = {
	reason = nil, -- 'launcher_outdated' | 'mods_outdated'
}

local create_UIBox_ranked_queue_cancelled_overlay = function()
	local body_key = _state.reason == 'launcher_outdated'
		and 'k_ranked_launcher_outdated_body'
		or 'k_ranked_mods_outdated_body'

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_ranked_queue_cancelled_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize(body_key), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_ranked_queue_cancelled_dismiss',
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

G.FUNCS.mpapi_ranked_queue_cancelled_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.ranked_queue_cancelled_overlay = MPAPI.ui_element(create_UIBox_ranked_queue_cancelled_overlay)

-- reason: 'launcher_outdated' | 'mods_outdated' (msg.reason straight off the
-- queue_cancelled matchmaking message - see dispatch.lua).
function MPAPI.show_ranked_queue_cancelled_notice(reason)
	_state.reason = reason
	MPAPI.ranked_queue_cancelled_overlay:as_overlay()
end
