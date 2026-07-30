-- Generic, reusable enemy-location HUD indicator: splices into the native
-- HUD's round/score row (row_dollars_chips), matching its stake-icon /
-- colored-swatch styling, with a hover popup for expanded detail.
--
-- Both PvP and SPDRN show *something* in this slot -- PvP's is the single
-- opposing nemesis (blind icon + name), SPDRN's is the furthest opponent's
-- run/ante across the whole lobby -- so the swap mechanics, hover wiring,
-- and shared row layout live here once. See
-- BalatroMultiplayerPvP/ui/game/enemy_location.lua and
-- BalatroMultiplayerSpeed/ui/enemy_location.lua for the two callers.
--
-- THE ONE RULE CALLERS MUST FOLLOW: config.build_value_nodes(chip_ui_id)
-- must set chip_ui_id as the `id` of (at least) one of its returned nodes.
-- functions/common_events.lua's ease_chips -- along with other base-game
-- code -- looks up G.HUD:get_UIE_by_ID('chip_UI_count') by that exact id on
-- every hand score, cash-out, and interest calculation, unconditionally, no
-- matter what's currently spliced into row_dollars_chips. If the current
-- content doesn't carry that id, those lookups return nil and the game
-- crashes outright. Both states built here -- the vanilla round/score
-- display and the indicator itself -- always carry it for exactly this
-- reason, so the swap is safe regardless of when it happens relative to
-- in-flight chip animations.
local _instance_counter = 0
local CHIP_UI_ID = 'chip_UI_count'

local function default_icon()
	return { n = G.UIT.O, config = { w = 0.5, h = 0.5, object = get_stake_sprite(G.GAME.stake or 1, 0.5), hover = true, can_collide = false } }
end

-- Shared [icon?][label][colored swatch] content, used for both the main
-- indicator and hover-popup rows. Returns a bare G.UIT.C -- correct when
-- this is the only thing occupying an existing row slot (the main
-- indicator, spliced in as row_dollars_chips's one child), but multiple
-- bare C nodes placed side by side under a shared parent (like the popup's
-- ROOT) lay out horizontally, not stacked -- see MPAPI.enemy_location_row
-- below for the version that stacks.
local function row_content(icon_node, label_nodes, value_nodes, minw)
	local nodes = {}
	if icon_node then
		nodes[#nodes + 1] = icon_node
	end
	nodes[#nodes + 1] = { n = G.UIT.C, config = { align = 'cm', minw = 1.2 }, nodes = label_nodes }
	nodes[#nodes + 1] = { n = G.UIT.C, config = { align = 'cm', minw = minw or 2.8, minh = 0.7, r = 0.1, colour = G.C.DYN_UI.BOSS_DARK }, nodes = value_nodes }
	return { n = G.UIT.C, config = { align = 'cm', padding = 0.1 }, nodes = nodes }
end

-- config:
--   label                          -- { line1, line2 }, e.g. {"Enemy", "Location"}
--   build_value_nodes(chip_ui_id)  -- -> array of nodes for the swatch; see header comment
--   build_popup_rows(major_node)   -- -> array of UI row defs shown on hover (nil/empty is fine)
--   icon()                         -- (optional) leading icon node; defaults to the stake sprite
--   swatch_minw                    -- (optional, default 2.8)
--
-- Returns a controller { show, hide, popup }. show()/hide() splice the
-- indicator in or out of row_dollars_chips; callers drive these from their
-- own state-transition hooks or a per-frame poll -- both are safe to call at
-- any time, including while chip-easing events are in flight, because of the
-- id guarantee above. Hover is wired onto BOTH states (so hovering the plain
-- chip counter during a blind, and hovering the indicator itself during
-- blind-select/shop, both work) and always shows the same popup content.
function MPAPI.enemy_location(config)
	_instance_counter = _instance_counter + 1
	local hover_func_name = 'mpapi_enemy_location_hover_' .. _instance_counter

	local ctrl = { popup = nil }

	local function round_score_definition()
		-- Vanilla is always {k_round, k_lower_score} in that order (see
		-- functions/UI_definitions.lua's own contents.dollars_chips); a
		-- caller can override via config.round_score_labels() for a
		-- locale-specific reading (PvP swaps this pair for "vi").
		local labels = config.round_score_labels and config.round_score_labels() or { localize('k_round'), localize('k_lower_score') }
		return {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.1, func = hover_func_name },
			nodes = {
				{ n = G.UIT.C, config = { align = 'cm', minw = 1.3 }, nodes = {
					{ n = G.UIT.R, config = { align = 'cm', padding = 0, maxw = 1.3 }, nodes = {
						{ n = G.UIT.T, config = { text = labels[1], scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					} },
					{ n = G.UIT.R, config = { align = 'cm', padding = 0, maxw = 1.3 }, nodes = {
						{ n = G.UIT.T, config = { text = labels[2], scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					} },
				} },
				{ n = G.UIT.C, config = { align = 'cm', minw = 3.3, minh = 0.7, r = 0.1, colour = G.C.DYN_UI.BOSS_DARK }, nodes = {
					(config.icon or default_icon)(),
					{ n = G.UIT.B, config = { w = 0.1, h = 0.1 } },
					{ n = G.UIT.T, config = { ref_table = G.GAME, ref_value = 'chips_text', lang = G.LANGUAGES['en-us'], scale = 0.85, colour = G.C.WHITE, id = CHIP_UI_ID, func = 'chip_UI_set', shadow = true } },
				} },
			},
		}
	end

	local function enemy_location_definition()
		local label_nodes = {}
		for _, line in ipairs(config.label) do
			label_nodes[#label_nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0, maxw = 1.2 }, nodes = {
				{ n = G.UIT.T, config = { text = line, scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} }
		end
		local def = row_content((config.icon or default_icon)(), label_nodes, config.build_value_nodes(CHIP_UI_ID), config.swatch_minw)
		def.config.func = hover_func_name
		return def
	end

	-- Opens ABOVE major_node (align 'tm' with a negative y offset positions
	-- this box's bottom edge just above major's top edge -- see
	-- Moveable:align_to_major in the base game engine: without the 'i'
	-- suffix, 't' anchors via `offset.y - self.T.h`, so the box's own height
	-- pushes it further up as it grows, rather than major's height pushing
	-- it further down).
	local function build_popup(major_node)
		local rows = config.build_popup_rows and config.build_popup_rows(major_node) or {}
		return UIBox({
			definition = { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, r = 0.25, emboss = 0.05, minw = 3.5 }, nodes = rows },
			config = { align = 'tm', offset = { x = 0, y = -0.15 }, major = major_node },
		})
	end

	-- Hand-rolled hover detection rather than the base-game Card h_popup/
	-- Node.hover mechanism, which requires the hovering element to be (or
	-- convincingly fake being) a Card -- this is attached to a plain UI
	-- node. A plain G.UIT.C node has no hover/collision detection by default
	-- (unlike a button), so both flags must be explicitly enabled.
	G.FUNCS[hover_func_name] = function(e)
		e.config.func = nil
		e.states.collide.can = true
		e.states.hover.can = true
		local old_hover = e.hover
		e.hover = function(self, ...)
			if old_hover then
				old_hover(self, ...)
			end
			if not ctrl.popup then
				local ok, popup = pcall(build_popup, self)
				if ok then
					ctrl.popup = popup
				end
			end
		end
		local old_stop_hover = e.stop_hover
		e.stop_hover = function(self, ...)
			if old_stop_hover then
				old_stop_hover(self, ...)
			end
			if ctrl.popup then
				pcall(function() ctrl.popup:remove() end)
				ctrl.popup = nil
			end
		end
		local old_remove = e.remove
		e.remove = function(self, ...)
			if ctrl.popup then
				pcall(function() ctrl.popup:remove() end)
				ctrl.popup = nil
			end
			return old_remove(self, ...)
		end
	end

	function ctrl.show()
		if not G.HUD then
			return
		end
		local hud_row = G.HUD:get_UIE_by_ID('row_dollars_chips')
		if hud_row and hud_row.children[1] then
			hud_row.children[1]:remove()
			hud_row.children[1] = nil
			G.HUD:add_child(enemy_location_definition(), hud_row)
		end
	end

	function ctrl.hide()
		if not G.HUD then
			return
		end
		local hud_row = G.HUD:get_UIE_by_ID('row_dollars_chips')
		if hud_row and hud_row.children[1] then
			hud_row.children[1]:remove()
			hud_row.children[1] = nil
			G.HUD:add_child(round_score_definition(), hud_row)
		end
	end

	return ctrl
end

-- Exposed for callers building custom popup content (e.g. SPDRN's
-- per-player roster): the same [icon?][label][swatch] styling as the main
-- indicator, wrapped in its own G.UIT.R so each call stacks as a separate
-- row when multiple are returned from build_popup_rows -- unlike
-- row_content above, this is never used for the main indicator itself
-- (that needs the bare, unwrapped content; see enemy_location_definition).
function MPAPI.enemy_location_row(icon_node, label_nodes, value_nodes, minw)
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { row_content(icon_node, label_nodes, value_nodes, minw) } }
end
