-----------------------------
-- End / result screen helpers
-----------------------------

-- Matches the base game's own 'seed' row (functions/UI_definitions.lua's
-- create_UIBox_round_scores_row: label_w = score_w = 1.9 for score == 'seed')
-- so the button column below it lines up with the seed box's actual width
-- instead of looking narrower.
local SEED_CONTAINER_W = 1.9 + 1.9

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
			minw = SEED_CONTAINER_W,
			maxw = SEED_CONTAINER_W,
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
	-- Always carry an id (even when the caller doesn't supply one) so the
	-- restorable-overlay mechanism below (MPAPI.end_screen_show /
	-- G.FUNCS.exit_overlay_menu) can always tell whether the currently-open
	-- overlay IS this end screen.
	t.config.id = config.id or 'mpapi_end_screen'
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
	local overlay_config = { no_esc = no_esc }
	-- Register this as the currently-pending "restorable" overlay BEFORE showing
	-- it, so if the pause/options menu (mod_registry/view.lua's G.FUNCS.options,
	-- reachable from the in-run HUD's Options button or Escape) or any other
	-- plain overlay_menu call (e.g. SPDRN's View Deck button,
	-- BalatroMultiplayerSpeed/ui/end_game_panel.lua's spdrn_view_selected_deck)
	-- opens on top and is later closed via G.FUNCS.exit_overlay_menu, this end
	-- screen is rebuilt and re-shown instead of being lost -- see the
	-- G.FUNCS.exit_overlay_menu wrap below. Rebuilding via
	-- MPAPI.end_screen_uibox(config), NOT end_screen_show(config), deliberately
	-- skips on_build/sounds/quip/room_jiggle -- those fire once, not per restore.
	MPAPI._restorable_overlay = {
		id = def.config.id,
		overlay_config = overlay_config,
		rebuild_fn = function()
			local rok, rdef = pcall(MPAPI.end_screen_uibox, config)
			return rok and rdef or def
		end,
	}
	G.FUNCS.overlay_menu({ definition = def, config = overlay_config })
	if config.room_jiggle and G.ROOM then
		G.ROOM.jiggle = G.ROOM.jiggle + config.room_jiggle
	end
	if config.quip then
		MPAPI.animate_jimbo_quip(config.quip.prefix, config.quip.max, config.quip.delay)
	end
end

-----------------------------
-- Overlay-over-overlay restore
-----------------------------

-- Balatro's G.FUNCS.overlay_menu is a hard singleton: opening a second overlay
-- unconditionally destroys whatever was already showing, and G.FUNCS.exit_overlay_menu
-- has no memory of what that was (base game functions/button_callbacks.lua).
-- MPAPI._restorable_overlay (set by MPAPI.end_screen_show, above) is the one
-- currently-pending overlay that should come back once whatever's on top of it
-- closes. PvP's own end screen has the identical latent bug -- it already has a
-- single-purpose rebuild (G.FUNCS.overlay_endgame_menu,
-- BalatroMultiplayerPvP/ui/game/functions.lua), wired only as its nemesis-deck-
-- viewer's back_func, not to this same pause-menu-close path. Not migrated here
-- (SPDRN-scoped fix); PvP could opt into this exact mechanism later by setting
-- MPAPI._restorable_overlay itself before its own overlay_menu call.
MPAPI._restorable_overlay = nil -- { id, overlay_config, rebuild_fn } or nil

local exit_overlay_menu_ref = G.FUNCS.exit_overlay_menu
G.FUNCS.exit_overlay_menu = function(...)
	local restorable = MPAPI._restorable_overlay
	-- Whichever overlay is open IS the restorable one iff its root node's config.id
	-- (set unconditionally by MPAPI.end_screen_uibox) is found via get_UIE_by_ID --
	-- NOT G.OVERLAY_MENU.config.id, which is the UIBox's own align/offset/no_esc config
	-- (set by G.FUNCS.overlay_menu's args.config), not the definition's root node config.
	local closing_is_restorable = restorable
		and G.OVERLAY_MENU
		and G.OVERLAY_MENU ~= true
		and G.OVERLAY_MENU:get_UIE_by_ID(restorable.id) ~= nil
	if closing_is_restorable then
		-- The restorable overlay itself is what's being dismissed (one of its own
		-- buttons, or Escape) -- forget it so nothing tries to resurrect it later.
		MPAPI._restorable_overlay = nil
	end
	exit_overlay_menu_ref(...)
	if restorable and not closing_is_restorable and G.OVERLAY_MENU == nil then
		-- Something else was closed while this overlay was still pending underneath
		-- it -- rebuild and bring it back rather than leaving the game board exposed.
		--
		-- Must set paused BEFORE overlay_menu, matching vanilla's own ordering
		-- (base game functions/button_callbacks.lua's G.FUNCS.options etc always
		-- pause first): engine/node.lua captures `created_on_pause = G.SETTINGS.paused`
		-- once, at construction, and engine/moveable.lua's Moveable:move (the per-frame
		-- position-easing update) permanently skips easing a node for which
		-- created_on_pause is false while paused is true. exit_overlay_menu_ref just
		-- set paused = false, so building the new UIBox before flipping it back true
		-- would freeze it at its pop-in start offset forever instead of sliding into place.
		G.SETTINGS.paused = true
		local def = restorable.rebuild_fn()
		G.FUNCS.overlay_menu({ definition = def, config = restorable.overlay_config })
	end
end

-----------------------------
-- End-screen player panel (jokers + selector)
-----------------------------

-- The standard "who's selected first" for an end-screen player panel: every
-- lobby member as options, defaulting to the local player. Shared by PvP
-- (you + your nemesis) and SPDRN (every racer) so both build their panel's
-- selector from the exact same lobby data instead of two parallel
-- implementations -- see BalatroMultiplayerPvP/ui/game/game_end.lua and
-- BalatroMultiplayerSpeed/ui/end_game_panel.lua for the two callers.
MPAPI.end_screen_default_selection = function(lobby)
	local players = (lobby and lobby:get_players()) or {}
	local options = {}
	local current_option = 1
	for i, p in ipairs(players) do
		options[i] = p.displayName or p.id
		if lobby and p.id == lobby.player_id then
			current_option = i
		end
	end
	if #options == 0 then
		options = { '--' }
	end
	return players, options, current_option
end

-- Rebuilds `area`'s cards from a plain-data joker list ({key, edition?,
-- eternal?, perishable?} per entry -- the shape both PvP's
-- PVP._collected_results and SPDRN's SPDRN._collected_results already use
-- for their own per-player end-of-run reports, see each mod's
-- pvp_player_result / spdrn_player_result). `jokers` may be nil (that
-- player's report hasn't arrived yet), which just empties the area.
MPAPI.rebuild_jokers_area = function(area, jokers)
	if not area then
		return
	end
	if area.cards then
		for _, card in ipairs(area.cards) do
			-- Avoid Jokers being removed from activating removal abilities
			-- (e.g. Negatives) as the area is cleared out from under them.
			card.added_to_deck = false
		end
		remove_all(area.cards)
	end
	area.cards = {}
	if not jokers then
		return
	end
	for _, j in ipairs(jokers) do
		local center = G.P_CENTERS[j.key]
		if center then
			local card = Card(area.T.x, area.T.y, G.CARD_W, G.CARD_H, nil, center, { bypass_discovery_center = true })
			if j.edition then
				card:set_edition(j.edition, true, true)
			end
			card.ability.eternal = j.eternal or false
			card.ability.perishable = j.perishable or false
			area:emplace(card)
		end
	end
end

-- A "View Deck" button styled to match the jokers area below it. `button` is
-- the caller's own G.FUNCS name -- deck fetch/format differs enough between
-- PvP (async network round-trip, tabbed you/nemesis viewer) and SPDRN
-- (synchronous decode of a broadcast string) that viewing stays entirely
-- caller-owned; this only standardizes the button's look.
MPAPI.end_screen_view_deck_button = function(button, label)
	return {
		n = G.UIT.C,
		config = { button = button, align = 'cm', padding = 0.12, colour = G.C.BLUE, emboss = 0.05, minh = 0.7, minw = 2, maxw = 2, r = 0.1, shadow = true, hover = true },
		nodes = { { n = G.UIT.T, config = { text = label or 'View Deck', colour = G.C.UI.TEXT_LIGHT, scale = 0.5, col = true } } },
	}
end

-- The [jokers label][jokers CardArea][player selector + View Deck button]
-- rows both PvP and SPDRN splice into their end-screen bodies -- this is the
-- part that used to be PvP's binary you/nemesis toggle_players_jokers
-- ("Enemy Jokers"/"Your Jokers") and, separately, SPDRN's own copy of this
-- same N-player selector. Callers keep their own state/G.FUNCS entry (rather
-- than this module owning a hidden one) so existing globals and tests stay
-- stable -- see the two callers for the concrete wiring.
-- config:
--   jokers_text_ref = { table, key }  -- ref_table/ref_value the caller keeps
--                                         updated (e.g. { SPDRN, 'end_game_jokers_text' })
--   jokers_area                       -- the CardArea built via MPAPI.rebuild_jokers_area
--   options, current_option           -- create_option_cycle's own contract
--   opt_callback                      -- G.FUNCS name string the caller defines
--   view_deck_button                  -- a node from MPAPI.end_screen_view_deck_button (or nil)
MPAPI.end_screen_player_panel = function(config)
	local selector_row_nodes = {
		{ n = G.UIT.C, config = { align = 'cm', minw = 3 }, nodes = {
			create_option_cycle({
				options = config.options,
				current_option = config.current_option,
				opt_callback = config.opt_callback,
				w = 3,
				cycle_shoulders = true,
				no_pips = true,
				focus_args = { snap_to = true, nav = 'wide' },
			}),
		} },
	}
	if config.view_deck_button then
		selector_row_nodes[#selector_row_nodes + 1] = { n = G.UIT.C, config = { minw = 0.15 } }
		selector_row_nodes[#selector_row_nodes + 1] = config.view_deck_button
	end

	return {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = config.jokers_text_ref.table, ref_value = config.jokers_text_ref.key, scale = config.jokers_text_scale or 0.7, maxw = 5, shadow = true } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			{ n = G.UIT.O, config = { object = config.jokers_area } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = selector_row_nodes },
	}
end

-- Relocated from PvP's ui/game/functions.lua: the shared body below embeds
-- the Ko-fi plug unconditionally now, and SPDRN doesn't depend on PvP being
-- installed, so the button's own handler needs to live somewhere both can
-- reach regardless of which one is actually present.
G.FUNCS.open_kofi = function(e)
	love.system.openURL('https://ko-fi.com/virtualized')
end

-- The full win/game-over screen BODY -- everything below the shared shell's
-- title (MPAPI.end_screen_uibox owns that part): the player panel, the
-- hand/poker-hand + stat grid, the Ko-fi plug, and a right column of
-- optional extra rows + seed/copy + buttons. Lifted directly from PvP's
-- original ui/game/game_end.lua end_game_body, since that's the version
-- both mods now use verbatim -- SPDRN used to have its own separate,
-- slightly different win_body/lose_body (different stat rows, no Ko-fi
-- plug); those differences are dropped for now in favor of one identical
-- screen, to be reintroduced later as config options if actually wanted.
-- config:
--   player_panel  -- rows from MPAPI.end_screen_player_panel
--   side_rows?    -- extra rows at the top of the right column, above seed
--                    (e.g. PvP's create_UIBox_round_scores_row_nemesis)
--   defeated_by?  -- (bool) show the base game's "Defeated By" row (SPDRN's
--                    run-lost-to-a-blind screen)
--   stat_rows?    -- overrides the left column's stat block entirely with a
--                    caller-supplied row node list (e.g. SPDRN's 4 match-wide
--                    stat rows, ui/end_game_panel.lua's build_end_game_stat_rows).
--                    Falls back to the base game's own hand/poker_hand/
--                    cards_purchased/times_rerolled/ante/round block when omitted.
--   buttons       -- button node list (from the caller's own end_screen_buttons)
MPAPI.end_screen_body = function(config)
	local left_col = {}
	if config.stat_rows then
		for _, row in ipairs(config.stat_rows) do
			left_col[#left_col + 1] = row
		end
	else
		left_col[#left_col + 1] = create_UIBox_round_scores_row('hand')
		left_col[#left_col + 1] = create_UIBox_round_scores_row('poker_hand')
		left_col[#left_col + 1] = {
			n = G.UIT.R,
			config = {},
			nodes = {
				{
					n = G.UIT.C,
					nodes = {
						create_UIBox_round_scores_row('cards_purchased', G.C.MONEY),
						{ n = G.UIT.R, config = { minh = 0.08 } },
						create_UIBox_round_scores_row('times_rerolled', G.C.GREEN),
					},
				},
				{ n = G.UIT.C, config = { minw = 0.08 } },
				{
					n = G.UIT.C,
					nodes = {
						create_UIBox_round_scores_row('furthest_ante', G.C.FILTER),
						{ n = G.UIT.R, config = { minh = 0.08 } },
						create_UIBox_round_scores_row('furthest_round', G.C.FILTER),
					},
				},
			},
		}
	end
	left_col[#left_col + 1] = { n = G.UIT.R, config = { minh = 0.01 } }
	left_col[#left_col + 1] = { n = G.UIT.R, config = { align = 'cm', minw = 2 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('ml_mp_kofi_message')[1], scale = 0.35, colour = G.C.UI.TEXT_LIGHT, col = true } },
	} }
	left_col[#left_col + 1] = { n = G.UIT.R, config = { align = 'cm', minw = 2 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('ml_mp_kofi_message')[2], scale = 0.35, colour = G.C.UI.TEXT_LIGHT, col = true } },
	} }
	left_col[#left_col + 1] = { n = G.UIT.R, config = { align = 'cm', minw = 2 }, nodes = {
		{ n = G.UIT.T, config = { text = localize('ml_mp_kofi_message')[3] .. (localize('ml_mp_kofi_message')[4] and (' ' .. localize('ml_mp_kofi_message')[4]) or ''), scale = 0.35, colour = G.C.UI.TEXT_LIGHT, col = true } },
	} }
	left_col[#left_col + 1] = { n = G.UIT.R, config = { minh = 0.08 } }
	left_col[#left_col + 1] = {
		n = G.UIT.R,
		config = { id = 'ko-fi_button', align = 'cm', padding = 0.1, r = 0.1, hover = true, colour = HEX('72A5F2'), button = 'open_kofi', shadow = true },
		nodes = {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0, no_fill = true, maxw = 3 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('b_mp_kofi_button'), scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
			} },
		},
	}

	local right_col = {}
	for _, row in ipairs(config.side_rows or {}) do
		right_col[#right_col + 1] = row
	end
	if config.defeated_by then
		right_col[#right_col + 1] = create_UIBox_round_scores_row('defeated_by')
	end
	right_col[#right_col + 1] = create_UIBox_round_scores_row('seed', G.C.WHITE)
	right_col[#right_col + 1] = UIBox_button({ id = 'copy_seed_button', button = 'copy_seed', label = { localize('b_copy') }, colour = G.C.BLUE, scale = 0.3, minw = SEED_CONTAINER_W, maxw = SEED_CONTAINER_W, minh = 0.4 })
	right_col[#right_col + 1] = { n = G.UIT.R, config = { align = 'cm', minh = 0.45, minw = 0.1 }, nodes = {} }
	for _, b in ipairs(config.buttons or {}) do
		right_col[#right_col + 1] = b
	end

	-- The player panel spans the FULL width, sitting above the two-column
	-- stats/seed/buttons split below it -- it is a sibling of that split
	-- row, not nested inside the left column, otherwise the right column
	-- (seed/buttons) ends up top-aligned next to the panel instead of
	-- starting below it.
	local rows = {}
	for _, row in ipairs(config.player_panel) do
		rows[#rows + 1] = row
	end
	rows[#rows + 1] = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{ n = G.UIT.C, config = { padding = 0.08 }, nodes = left_col },
			{ n = G.UIT.C, config = { align = 'tr', padding = 0.08 }, nodes = right_col },
		},
	}

	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.15 },
		nodes = {
			{ n = G.UIT.C, config = { align = 'cm' }, nodes = rows },
		},
	}
end

-----------------------------
-- Jimbo quip
-----------------------------

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
