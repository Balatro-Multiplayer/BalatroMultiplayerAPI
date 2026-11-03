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
	open = false,
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
	if _state.checking then
		return create_UIBox_generic_options({
			no_back = true,
			no_esc = true,
			contents = {
				{
					n = G.UIT.C,
					config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
					nodes = { text_row(localize('k_rejoin_checking'), 0.5) },
				},
			},
		})
	end
	local rows = {
		text_row(localize('k_rejoin_refused_title'), 0.55),
		text_row(S.refusal_lead(refusal, S.RefusalContext.REJOIN), 0.35),
	}
	if #refusal.mods > 0 then
		rows[#rows + 1] = text_row(S.format_mods(S.mod_names(refusal.mods)), 0.4, G.C.RED)
	end
	local final = S.is_final_refusal(refusal)
	local buttons = {}
	if final then
		local seconds = tostring(MPAPI.networking.nakama_lobby.seat_grace_seconds_left())
		rows[#rows + 1] = text_row((localize('k_rejoin_refused_hint_failed'):gsub('#1#', seconds)), 0.32)
		buttons[#buttons + 1] = button_column('b_quit_game', 'mpapi_rejoin_refused_quit', G.C.ORANGE)
	else
		rows[#rows + 1] = text_row(localize('k_rejoin_refused_hint'), 0.32)
		buttons[#buttons + 1] = button_column('b_retry', 'mpapi_rejoin_refused_retry', G.C.GREEN)
	end
	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
	buttons[#buttons + 1] = { n = G.UIT.C, config = { minw = 0.3 } }
	buttons[#buttons + 1] = button_column('b_leave_game_forfeit', 'mpapi_rejoin_refused_leave', G.C.RED)
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = buttons }

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
	_state.open = false
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
end

-- Back into the seat the server kept, or, when it is gone (the game ended
-- while the refusal was up), the same notice as a seat given up at the grace
-- limit: a run with no lobby behind it must not become playable.
local function reconnect_to_seat()
	MPAPI._internal.lobby.nakama_check_current(function(seat)
		if seat then
			MPAPI._internal.reconnect_to(seat)
			return
		end
		close_overlay()
		MPAPI.show_connection_lost_notice()
	end)
end

-- Re-reports the mods (the fix the player made is only seen in a new report),
-- then reconnects to the seat. That checks the standing again (and, for a game
-- needing a verified account, starts Launcher verification again and waits
-- for the verdict). The overlay says it is checking until then.
G.FUNCS.mpapi_rejoin_refused_retry = function(e)
	MPAPI.rejoin_recheck.reset()
	MPAPI.show_rejoin_checking()
	MPAPI._internal.send_installed_mods(reconnect_to_seat)
end

-- Closes the game and keeps the seat: no lobby leave, so the player can start
-- again through BET while the server still holds it.
G.FUNCS.mpapi_rejoin_refused_quit = function(e)
	love.event.quit()
end

G.FUNCS.mpapi_rejoin_refused_leave = function(e)
	MPAPI.rejoin_recheck.reset()
	close_overlay()
	-- Money and round events queued by the dead run would run against a HUD
	-- that go_to_menu is about to delete.
	if G.E_MANAGER then
		G.E_MANAGER:clear_queue()
	end
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

local function show_overlay()
	if _state.open then
		MPAPI.rejoin_refused_overlay:update()
		return
	end
	_state.open = true
	-- Paused before the overlay is built, as vanilla does, so the run behind
	-- it stands still until the player picks Retry or Leave.
	G.SETTINGS.paused = true
	MPAPI.rejoin_refused_overlay:as_overlay({ no_esc = true })
end

-- The overlay is the only way out of a refused rejoin: if something else
-- closes the overlay menu while the refusal is open, bring it back.
local MPAPI_update_ref = MPAPI.update
MPAPI.update = function(...)
	if _state.open and not G.OVERLAY_MENU then
		_state.open = false
		show_overlay()
	end
	return MPAPI_update_ref(...)
end

function MPAPI.show_rejoin_checking()
	_state.checking = true
	show_overlay()
end

function MPAPI.close_rejoin_overlay()
	if _state.open then
		close_overlay()
	end
end

-- refusal: {code (MPAPI.RejoinRefusalCode), mods}, from
-- MPAPI.standing.rejoin_refusal or parse_rejoin_refusal. opts.waited: this
-- refusal already followed a wait for the launcher verdict.
function MPAPI.show_rejoin_refused(refusal, opts)
	_state.refusal = { code = refusal.code, mods = refusal.mods or {} }
	if MPAPI.rejoin_recheck.due(refusal, opts and opts.waited) then
		MPAPI.show_rejoin_checking()
		local seat_refusal = _state.refusal
		MPAPI.rejoin_recheck.run(function(outcome)
			if outcome == MPAPI.VerdictOutcome.VERIFIED then
				reconnect_to_seat()
			elseif outcome == MPAPI.VerdictOutcome.FAILED then
				MPAPI.show_rejoin_refused({ code = MPAPI.RejoinRefusalCode.VERIFICATION_FAILED, mods = {} }, { waited = true })
			else
				MPAPI.show_rejoin_refused(seat_refusal, { waited = true })
			end
		end)
		return
	end
	_state.checking = false
	show_overlay()
end

-- The inspection hook ClaudeControl's suites read: the refusal last shown.
function MPAPI._internal.shown_rejoin_refusal()
	return _state.refusal
end
