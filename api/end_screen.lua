-----------------------------
-- End / result screen helpers
-----------------------------

-- Builds a stack of uniformly-styled action buttons for an end / result screen,
-- matching the base game's end-of-run button styling (fixed width, wide controller
-- nav, the first button focus-snapped). `specs` is a list of:
--   { button = <G.FUNCS key>, label = <string>, colour = <G.C.* > }
-- Returns the list of button nodes to splice into a column.
MPAPI.end_screen_buttons = function(specs)
	local btns = {}
	for _, spec in ipairs(specs) do
		btns[#btns + 1] = UIBox_button({
			button = spec.button,
			label = { spec.label },
			colour = spec.colour,
			minw = 2.5,
			maxw = 2.5,
			minh = 0.85,
			scale = 0.32,
			focus_args = { nav = 'wide', snap_to = (#btns == 0) },
		})
	end
	return btns
end

-- Swaps the placeholder 'jimbo_spot' Moveable in the currently-open overlay for an
-- animated Jimbo that says a random quip, after `delay` seconds (default 2.5). The
-- screen must reserve a node carrying id 'jimbo_spot' (a Moveable sized to a card).
-- quip_prefix + quip_max choose the speech-bubble key, e.g. ('wq_', 7) picks one of
-- 'wq_1'..'wq_7'.
MPAPI.animate_jimbo_quip = function(quip_prefix, quip_max, delay)
	G.E_MANAGER:add_event(Event({
		trigger = 'after',
		delay = delay or 2.5,
		blocking = false,
		func = function()
			if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true and G.OVERLAY_MENU:get_UIE_by_ID('jimbo_spot') then
				local Jimbo = Card_Character({ x = 0, y = 5 })
				local spot = G.OVERLAY_MENU:get_UIE_by_ID('jimbo_spot')
				spot.config.object:remove()
				spot.config.object = Jimbo
				Jimbo.ui_object_updated = true
				Jimbo:add_speech_bubble(quip_prefix .. math.random(1, quip_max), nil, { quip = true })
				Jimbo:say_stuff(5)
			end
			return true
		end,
	}))
end
