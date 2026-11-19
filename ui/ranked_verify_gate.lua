-- The startup "verifying Ranked status" overlay. The state machine itself is
-- anticheat/verify_gate.lua (no UI in there); this file is only the screens
-- and the glue that starts it once the main menu is up.
--
-- Applies to a Ranked launch through BET (MPAPI.anticheat.active) on the
-- Official server only: that is the one place "verified" means anything.
-- Community and Dev servers never ask the launcher, so nothing is held back.
--
-- The overlay deliberately covers the whole main menu rather than just
-- disabling the Ranked button: the point is to settle verification before
-- anything else on the menu can be used. It is re-shown every frame while the
-- gate is blocking, so ESC or another overlay closing it can't be a way past
-- the prompt (which only ever offers "keep waiting" or "give up").

local _shown = nil -- 'verifying' | 'prompting' | nil: which screen is up
local _menu_ready = false

local function gate()
	return MPAPI.anticheat and MPAPI.anticheat.gate
end

local function text_row(key, scale, padding)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = padding or 0.06 },
		nodes = {
			{ n = G.UIT.T, config = { text = localize(key), scale = scale, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		},
	}
end

local function button_row(label_key, func, colour)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.08 },
		nodes = {
			{ n = G.UIT.C, config = {
				align = 'cm', padding = 0.15, minw = 6, minh = 0.7, r = 0.1,
				colour = colour, shadow = true, hover = true, button = func,
			}, nodes = {
				{ n = G.UIT.T, config = { text = localize(label_key), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
		},
	}
end

local function wrap(rows)
	return create_UIBox_generic_options({
		no_back = true,
		no_esc = true,
		contents = {
			{ n = G.UIT.C, config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR }, nodes = rows },
		},
	})
end

local verifying_overlay = MPAPI.ui_element(function()
	return wrap({
		text_row('k_ranked_verifying_title', 0.55, 0.1),
		text_row('k_ranked_verifying_body', 0.32),
	})
end)

local prompt_overlay = MPAPI.ui_element(function()
	return wrap({
		text_row('k_ranked_verify_failed_title', 0.55, 0.1),
		text_row('k_ranked_verify_failed_body_1', 0.32),
		text_row('k_ranked_verify_failed_body_2', 0.32),
		{ n = G.UIT.R, config = { minh = 0.2 } },
		button_row('k_ranked_verify_keep_waiting', 'mpapi_ranked_verify_keep_waiting', G.C.BLUE),
		button_row('k_ranked_verify_give_up', 'mpapi_ranked_verify_give_up', G.C.RED),
	})
end)

local function show(which)
	if _shown == which and G.OVERLAY_MENU then
		return
	end
	_shown = which
	local el = which == 'prompting' and prompt_overlay or verifying_overlay
	el:as_overlay({ no_esc = true })
end

local function clear()
	if _shown and G.OVERLAY_MENU then
		G.FUNCS.exit_overlay_menu()
	end
	_shown = nil
end

G.FUNCS.mpapi_ranked_verify_keep_waiting = function(e)
	local g = gate()
	if g then
		g:keep_waiting()
	end
end

G.FUNCS.mpapi_ranked_verify_give_up = function(e)
	local g = gate()
	if g then
		g:bypass()
	end
end

-- Terminal states take the overlay down; the gate's hooks are set up by
-- anticheat/launcher_channel.lua (it owns the launcher side of things), so
-- the UI-only ones are attached here.
local function attach_ui_hooks(g)
	if g._ui_hooked then
		return
	end
	g._ui_hooked = true
	g.hooks.on_done = function()
		clear()
	end
end

local function applies()
	local A = MPAPI.anticheat
	local C = MPAPI._internal and MPAPI._internal.conn
	return A ~= nil and A.active and A.gate ~= nil and C ~= nil and C.is_official_server()
end

local _set_main_menu_UI_ref = set_main_menu_UI
set_main_menu_UI = function()
	_set_main_menu_UI_ref()
	_menu_ready = true
end

local _update_ref = MPAPI.update
MPAPI.update = function()
	local g = applies() and gate() or nil
	if g then
		attach_ui_hooks(g)
		if _menu_ready and g.state == MPAPI.anticheat.GateState.IDLE then
			g:start()
		end
		if g:is_blocking() and _menu_ready and G.STAGE == G.STAGES.MAIN_MENU then
			local want = (g.state == MPAPI.anticheat.GateState.PROMPTING) and 'prompting' or 'verifying'
			-- Never replace an overlay that isn't ours (e.g. the TOS prompt);
			-- the window keeps running meanwhile, which at worst turns into
			-- the keep-waiting prompt once that overlay is closed.
			if (not G.OVERLAY_MENU) or (_shown ~= nil and _shown ~= want) then
				show(want)
			end
		end
	end
	_update_ref()
end
