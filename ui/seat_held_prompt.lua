-- Shown when the server refuses a lobby create or join because this account
-- still holds a seat (one seat per account, across every mod: "Already in
-- lobby ABCD"). The seat can be in another mod's game, whose menu doesn't know
-- about it, so the choice is offered here for every mod: Rejoin the seat's
-- game (switching to its mod) or Leave it.
local mod_state = MPAPI._internal.mod_registry

local SEAT_HELD_PATTERN = '^Already in lobby'

local _state = {
	seat = nil,
}

local function mod_display_name(mod_id)
	local mod = mod_state.registered_mods[mod_id]
	return (mod and mod.name) or MPAPI.standing.mod_name(mod_id)
end

-- A seat can only be rejoined from a mod this game has installed: its pages
-- and its lobby_reconnect handler live in that mod.
local function can_rejoin(seat)
	local mod = mod_state.registered_mods[seat.modId]
	return mod ~= nil and mod.main_menu_ui ~= nil
end

local function text_row(text, scale, colour)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.06 },
		nodes = {
			{ n = G.UIT.T, config = { text = text, scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } },
		},
	}
end

local function button_column(label, button, colour)
	return {
		n = G.UIT.C,
		config = { align = 'cm' },
		nodes = {
			UIBox_button({ label = { label }, button = button, minw = 3, minh = 0.8, scale = 0.4, colour = colour }),
		},
	}
end

local function create_UIBox_seat_held_prompt()
	local seat = _state.seat or {}
	local body = localize('k_seat_held_body'):gsub('#1#', mod_display_name(seat.modId))
	local buttons = {}
	if can_rejoin(seat) then
		buttons[#buttons + 1] = button_column(localize('b_seat_held_rejoin'), 'mpapi_seat_held_rejoin', G.C.GREEN)
		buttons[#buttons + 1] = { n = G.UIT.C, config = { minw = 0.3 } }
	end
	buttons[#buttons + 1] = button_column(localize('b_seat_held_leave'), 'mpapi_seat_held_leave', G.C.RED)

	local rows = {
		text_row(localize('k_seat_held_title'), 0.55),
		text_row(body, 0.38),
		{ n = G.UIT.R, config = { minh = 0.2 } },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = buttons },
	}
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = rows,
		},
	}
	return create_UIBox_generic_options({ contents = contents })
end

local function close_prompt()
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
end

-- reconnect_to (ui/reconnect_prompt.lua) already routes by the seat's modId:
-- a seat with a run in progress goes through that mod's playback rejoin (which
-- focuses the mod for the run), a waiting-room seat through its
-- lobby_reconnect, then activate_mod opens that mod's lobby page.
G.FUNCS.mpapi_seat_held_rejoin = function()
	local seat = _state.seat
	_state.seat = nil
	close_prompt()
	if seat and can_rejoin(seat) then
		MPAPI._internal.reconnect_to(seat)
	end
end

G.FUNCS.mpapi_seat_held_leave = function()
	_state.seat = nil
	close_prompt()
	MPAPI._internal.lobby.nakama_leave_current(function(err)
		if err then
			MPAPI.sendWarnMessage('[seat_held] lobby_leave failed: ' .. tostring(err))
		end
	end)
end

MPAPI.seat_held_prompt = MPAPI.ui_element(create_UIBox_seat_held_prompt)

-- seat: { matchId, code, modId, ... } from lobby_current.
function MPAPI.show_seat_held_prompt(seat)
	_state.seat = seat
	MPAPI.seat_held_prompt:as_overlay()
end

function MPAPI._internal.is_seat_held_refusal(message)
	return type(message) == 'string' and message:find(SEAT_HELD_PATTERN) ~= nil
end

-- cb(true) once the prompt is up; cb(false) when the server no longer reports
-- a seat (it was let go meanwhile), so the caller shows its own refusal.
function MPAPI._internal.offer_held_seat(cb)
	MPAPI._internal.lobby.nakama_check_current(function(seat)
		if not seat then
			cb(false)
			return
		end
		MPAPI.show_seat_held_prompt(seat)
		cb(true)
	end)
end

-- The inspection hook ClaudeControl's suites read: the seat last offered.
function MPAPI._internal.shown_held_seat()
	return _state.seat
end
