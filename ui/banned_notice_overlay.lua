-- Shown when the server bans this player, or refuses a login because the
-- account or network is banned (Nakama only: see
-- api/connection/moderation.lua). Same small modal shape as
-- ui/kicked_notice_overlay.lua, with the server's
-- wording as the body.
local _state = {
	title_key = 'k_banned_title',
	body = '',
}

local create_UIBox_banned_notice_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize(_state.title_key), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = _state.body, scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_banned_notice_dismiss',
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

G.FUNCS.mpapi_banned_notice_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.banned_notice_overlay = MPAPI.ui_element(create_UIBox_banned_notice_overlay)

-- A titled one-line notice with an OK button. title_key: a localization
-- key; body: the text to show (usually the server's own wording).
-- The same notice raised again while its overlay is still up is dropped:
-- two callers can report one refusal.
function MPAPI.show_notice(title_key, body)
	body = body or ''
	if _state.shown and _state.shown == G.OVERLAY_MENU and _state.title_key == title_key and _state.body == body then
		return
	end
	_state.title_key = title_key
	_state.body = body
	MPAPI.banned_notice_overlay:as_overlay()
	_state.shown = G.OVERLAY_MENU
end

-- title_key: k_banned_title, k_network_banned_title, k_queue_banned_title or
-- k_chat_banned_title.
function MPAPI.show_banned_notice(title_key, body)
	MPAPI.show_notice(title_key or 'k_banned_title', body)
end
