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

-- Builds the shared win / game-over UIBox shell used by consumer mods: the eased
-- green/red background, the ph_you_win / ph_game_over DynaText title (rotating +
-- spaced on a win), and the two-column wrap that reserves the 'jimbo_spot'. The caller
-- supplies the body (stats / buttons / mod-specific content) via config.body(won).
-- config = {
--   won        (bool)                          -- win vs game-over,
--   body       = function(won) -> UIT node,    -- appended after the title,
--   title_key?, title_colour?,                 -- default ph_you_win/ph_game_over + EDITION/RED,
--   bg_colour?, bg_alpha?,                      -- default GREEN/RED + 0.5/0.8,
--   win_fill?  (default G.C.BLACK),             -- generic-options fill, win only,
--   win_outline? (default G.C.EDITION),        -- generic-options outline, win only,
--   no_esc?    (default = won),                 -- allow ESC on a loss by default,
--   id?,                                        -- t.config.id (e.g. 'you_win_UI'),
-- }
MPAPI.end_screen_uibox = function(config)
	local won = config.won
	local bg = copy_table(config.bg_colour or (won and G.C.GREEN or G.C.RED))
	bg[4] = 0
	ease_value(bg, 4, config.bg_alpha or (won and 0.5 or 0.8), nil, nil, true)

	local no_esc = config.no_esc
	if no_esc == nil then no_esc = won end

	local contents = {
		{
			n = G.UIT.R,
			config = { align = 'cm' },
			nodes = {
				{ n = G.UIT.O, config = { object = DynaText({
					string = { localize(config.title_key or (won and 'ph_you_win' or 'ph_game_over')) },
					colours = { config.title_colour or (won and G.C.EDITION or G.C.RED) },
					shadow = true,
					float = true,
					spacing = won and 10 or nil,
					rotate = won or nil,
					scale = 1.5,
					pop_in = 0.4,
					maxw = 6.5,
				}) } },
			},
		},
	}
	local body = config.body and config.body(won)
	if body then
		contents[#contents + 1] = body
	end

	local t = create_UIBox_generic_options({
		padding = 0,
		bg_colour = bg,
		colour = won and (config.win_fill or G.C.BLACK) or nil,
		outline_colour = won and (config.win_outline or G.C.EDITION) or nil,
		no_back = true,
		no_esc = no_esc,
		contents = contents,
	})

	-- Two-column wrap of the title row: a reserved jimbo_spot on the left, the title on
	-- the right (animate_jimbo_quip swaps the spot in after a delay).
	t.nodes[1] = {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.1 },
		nodes = {
			{ n = G.UIT.C, config = { align = 'cm', padding = 2 }, nodes = {
				{ n = G.UIT.O, config = { padding = 0, id = 'jimbo_spot', object = Moveable(0, 0, G.CARD_W * 1.1, G.CARD_H * 1.1) } },
			} },
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.1 }, nodes = { t.nodes[1] } },
		},
	}
	if config.id then
		t.config.id = config.id
	end
	return t
end

-- Shows an end screen as an overlay with the full shared lifecycle: an optional
-- on_build hook (e.g. to kick off async data), sound(s), pause, the shell UIBox, an
-- optional room jiggle, and the delayed Jimbo quip. config = end_screen_uibox config +
--   on_build? = function(won),
--   sounds?   = <sound key string> or { { key, pitch?, volume? }, ... },
--   quip?     = { prefix, max, delay? },
--   room_jiggle? (number),
MPAPI.end_screen_show = function(config)
	if config.on_build then
		config.on_build(config.won)
	end
	local ok, def = pcall(MPAPI.end_screen_uibox, config)
	if not ok then
		MPAPI.sendWarnMessage('end_screen_show: build error: ' .. tostring(def))
		return
	end
	if type(config.sounds) == 'string' then
		play_sound(config.sounds)
	elseif type(config.sounds) == 'table' then
		for _, s in ipairs(config.sounds) do
			play_sound(s.key or s[1], s.pitch or s[2], s.volume or s[3])
		end
	end
	G.SETTINGS.paused = true
	local no_esc = config.no_esc
	if no_esc == nil then no_esc = config.won end
	G.FUNCS.overlay_menu({ definition = def, config = { no_esc = no_esc } })
	if config.room_jiggle and G.ROOM then
		G.ROOM.jiggle = G.ROOM.jiggle + config.room_jiggle
	end
	if config.quip then
		MPAPI.animate_jimbo_quip(config.quip.prefix, config.quip.max, config.quip.delay)
	end
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
