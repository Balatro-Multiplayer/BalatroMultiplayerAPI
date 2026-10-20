-- Shown when a matchmade game won't take this account back because of its
-- standing (api/connection/standing.lua): checked before the reconnect
-- (ui/reconnect_prompt.lua) and again from the server's match_join refusal
-- (api/lobby/nakama.lua). The server keeps the seat, so the choice is forced
-- like the reconnect prompt's: Retry after fixing the mods, or leave the game,
-- which forfeits it.
local S = MPAPI.standing

local _state = {
	refusal = { code = MPAPI.RejoinRefusalCode.MODS_NOT_ALLOWED, mods = {} },
	checking = false,
}

local function text_row(text, scale, colour)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.06 },
		nodes = {
			{ n = G.UIT.T, config = { text = text, scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } },
		},
	}
end

local function button_column(label_key, button, colour)
	return {
		n = G.UIT.C,
		config = { align = 'cm' },
		nodes = {
			UIBox_button({ label = { localize(label_key) }, button = button, minw = 3.6, minh = 0.8, scale = 0.4, colour = colour }),
		},
	}
end

local create_UIBox_rejoin_refused_overlay = function()
	local refusal = _state.refusal
	local rows = {
		text_row(localize('k_rejoin_refused_title'), 0.55),
		text_row(S.refusal_lead(refusal, S.RefusalContext.REJOIN), 0.35),
	}
	if #refusal.mods > 0 then
		rows[#rows + 1] = text_row(S.format_mods(S.mod_names(refusal.mods)), 0.4, G.C.RED)
	end
	rows[#rows + 1] = text_row(localize('k_rejoin_refused_hint'), 0.32)
	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
	if _state.checking then
		rows[#rows + 1] = text_row(localize('k_rejoin_checking'), 0.4, G.C.UI.TEXT_INACTIVE)
	else
		rows[#rows + 1] = {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.15 },
			nodes = {
				button_column('b_retry', 'mpapi_rejoin_refused_retry', G.C.GREEN),
				{ n = G.UIT.C, config = { minw = 0.3 } },
				button_column('b_leave_game_forfeit', 'mpapi_rejoin_refused_leave', G.C.RED),
			},
		}
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = rows,
		},
	}
	return create_UIBox_generic_options({ no_back = true, no_esc = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

local function close_overlay()
	_state.checking = false
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
end

-- Re-reports the mods (the fix the player made is only seen in a new report),
-- then reconnects to the seat the server kept, which checks the standing
-- again and shows this overlay again if it still falls short.
G.FUNCS.mpapi_rejoin_refused_retry = function(e)
	_state.checking = true
	MPAPI.rejoin_refused_overlay:update()
	MPAPI._internal.send_installed_mods(function()
		MPAPI._internal.lobby.nakama_check_current(function(seat)
			close_overlay()
			if seat then
				MPAPI._internal.reconnect_to(seat)
			end
		end)
	end)
end

G.FUNCS.mpapi_rejoin_refused_leave = function(e)
	close_overlay()
	MPAPI._internal.lobby.nakama_leave_current(function(err)
		if err then
			MPAPI.sendWarnMessage('[rejoin_refused] lobby_leave failed: ' .. tostring(err))
		end
	end)
	-- A refusal at the join can land mid fast-forward, inside the replayed run.
	if G.STAGE ~= G.STAGES.MAIN_MENU then
		G.FUNCS.go_to_menu()
	end
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.rejoin_refused_overlay = MPAPI.ui_element(create_UIBox_rejoin_refused_overlay)

-- refusal: {code (MPAPI.RejoinRefusalCode), mods}, from
-- MPAPI.standing.rejoin_refusal or parse_rejoin_refusal.
function MPAPI.show_rejoin_refused(refusal)
	_state.refusal = { code = refusal.code, mods = refusal.mods or {} }
	_state.checking = false
	MPAPI.rejoin_refused_overlay:as_overlay({ no_esc = true })
end

-- The inspection hook ClaudeControl's suites read: the refusal last shown.
function MPAPI._internal.shown_rejoin_refusal()
	return _state.refusal
end
