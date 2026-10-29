-- Shown when a queue is pressed, or a ticket is cancelled, because of the
-- account's standing (api/connection/standing.lua): every mod that isn't
-- allowed, by SMODS id, or that the game hasn't reported its mods, or that
-- Ranked needs a launcher-verified game. Same small modal shape as
-- ui/ranked_queue_cancelled_overlay.lua; shown centrally here so PvP and
-- SPDRN don't each word it.
local S = MPAPI.standing
local Refusal = MPAPI.QueueRefusalCode

local _state = {
	refusal = { code = Refusal.MODS_NOT_ALLOWED, mods = {} },
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

local function title_key(code)
	local key = 'k_queue_refused_title_' .. tostring(code)
	return localize(key) ~= 'ERROR' and key or 'k_queue_failed_title'
end

local create_UIBox_mods_not_allowed_overlay = function()
	local refusal = _state.refusal
	local rows = {
		text_row(localize(title_key(refusal.code)), 0.55),
		text_row(S.refusal_lead(refusal, S.RefusalContext.QUEUE), 0.35),
	}
	for _, line in ipairs(S.mod_id_lines(refusal.mods)) do
		rows[#rows + 1] = text_row(line, 0.4, G.C.RED)
	end
	local hint = localize('k_queue_refused_hint_' .. tostring(refusal.code))
	if hint ~= 'ERROR' then
		rows[#rows + 1] = text_row(hint, 0.32)
	end
	if refusal.code == Refusal.MODS_NOT_ALLOWED or refusal.code == Refusal.MODS_UNREPORTED then
		rows[#rows + 1] = text_row(localize('k_queue_refused_private_ok'), 0.3, G.C.UI.TEXT_INACTIVE)
	end
	rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
	rows[#rows + 1] = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{ n = G.UIT.C, config = {
				align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
				colour = G.C.RED, shadow = true, hover = true, button = 'mpapi_mods_not_allowed_dismiss',
			}, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_ok'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
		},
	}

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = rows,
		},
	}
	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_mods_not_allowed_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.mods_not_allowed_overlay = MPAPI.ui_element(create_UIBox_mods_not_allowed_overlay)

-- refusal: {code (MPAPI.QueueRefusalCode), mods}, from MPAPI.can_queue or a
-- QUEUE_CANCELLED push.
function MPAPI.show_standing_refusal(refusal)
	_state.refusal = { code = refusal.code, mods = refusal.mods or {} }
	MPAPI.mods_not_allowed_overlay:as_overlay()
end

-- The inspection hook ClaudeControl's suites read: the refusal last shown.
function MPAPI._internal.shown_standing_refusal()
	return _state.refusal
end
