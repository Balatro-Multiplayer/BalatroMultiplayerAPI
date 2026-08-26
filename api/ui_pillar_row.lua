-----------------------------
-- Generic pillar-select row
-----------------------------
-- A horizontal row of vertical "pillar" cards, styled after Balatro's own Blind Select
-- pillars (functions/UI_definitions.lua's create_UIBox_blind_choice) -- a SELECT button, a
-- name plate, an icon slot, a description box, and a stat box, stacked in a tall column that
-- stretches to fill the page. Extracted from BalatroMultiplayerSpeed's gamemode-select screen
-- (ui/main_menu/game_select.lua) so any MPAPI-consuming mod can build its own pillar picker
-- (a gamemode select, a deck select, a ruleset select, ...) without reimplementing the shape.
--
-- Pure UI-definition code -- knows nothing about MPAPI's page system (api/page/). Build it
-- once per "show" and call :dispose() exactly once when the row leaves the screen, whatever
-- owns its lifetime (a page's own dispose() hook, an overlay's close handler, ...): Balatro's
-- own Node:remove() does not cascade into a G.UIT.O node's embedded object (Sprite/
-- AnimatedSprite/...), so any pillar using `icon` leaks/crashes on the next frame without this
-- -- same reasoning SPDRN's own sprite_tracker/dispose_game_select_sprites existed for before
-- this extraction. Building a second row (or the same page again) without disposing the first
-- leaks its icons exactly the same way -- one build, one dispose, same discipline throughout.

-----------------------------
-- Shared shell + content helpers
-----------------------------

-- The shared dark embossed box shell reused below by description boxes, stat boxes, and any
-- other "small info card" a pillar (or anything else entirely) wants -- unprefixed since it's
-- useful well beyond pillars specifically.
MPAPI.ui_embossed_box = function(spec)
	spec = spec or {}
	return { n = G.UIT.R, config = {
		align = 'cm', r = spec.r or 0.1, padding = spec.padding or 0.06,
		minw = spec.minw, minh = spec.minh, colour = spec.colour or G.C.BLACK, emboss = spec.emboss or 0.05,
	}, nodes = spec.nodes or {} }
end

-- A static SELECT/CREATE/START-style button: one colour+label, greyed out and non-interactive
-- when disabled. For anything needing live in-place refresh (a queue/cancel toggle, a state
-- that changes without a page rebuild), build an MPAPI.ui_element-wrapped node directly instead
-- and hand it to ui_pillar_row as `item.select` -- the row builder never interprets that field,
-- so a fully custom reactive node fits exactly where this helper's output would.
MPAPI.ui_pillar_select_button = function(spec)
	spec = spec or {}
	local config = {
		align = 'cm', minh = spec.minh or 0.5, minw = spec.minw or 2.2, padding = 0.06, r = 0.1,
		colour = spec.disabled and G.C.UI.BACKGROUND_INACTIVE or (spec.colour or G.C.ORANGE),
	}
	if not spec.disabled then
		config.shadow = true
		config.hover = true
		config.one_press = true
		config.button = spec.button
		config.ref_table = spec.ref_table
	end
	return { n = G.UIT.R, config = config, nodes = {
		{ n = G.UIT.T, config = { text = spec.label, scale = 0.4, colour = spec.disabled and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT, shadow = not spec.disabled } },
	} }
end

-- The outlined/embossed name card. `lines` is either a plain string (one line) or a
-- {line1, line2} table -- minh is fixed regardless of line count so a single-line name centers
-- inside the same card size a two-line name naturally fills, keeping every pillar in a row the
-- same height.
MPAPI.ui_pillar_name_plate = function(spec)
	spec = spec or {}
	local lines = type(spec.lines) == 'table' and spec.lines or { spec.lines }
	local text_nodes = {}
	for _, line in ipairs(lines) do
		text_nodes[#text_nodes + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
			{ n = G.UIT.T, config = { text = line, scale = 0.35, colour = G.C.WHITE, shadow = true, maxw = 2.2 } },
		} }
	end
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
		{ n = G.UIT.R, config = {
			align = 'cm', r = 0.1, outline = 1, outline_colour = spec.outline_colour or G.C.WHITE,
			colour = spec.bg_colour or G.C.BLACK, minw = spec.minw or 2.3, minh = spec.minh or 0.95,
			emboss = 0.1, padding = 0.06, line_emboss = 1,
		}, nodes = text_nodes },
	} }
end

-- Small, secondary-info caption style -- a dimmer, smaller line under a main label.
local function small_caption(text)
	return { n = G.UIT.R, config = { align = 'cm' }, nodes = {
		{ n = G.UIT.T, config = { text = text, scale = 0.28, colour = G.C.UI.TEXT_INACTIVE, shadow = false } },
	} }
end

-- N centered lines in an embossed box, plus one optional dim caption line underneath (e.g. a
-- time limit, a player count) -- minh is fixed regardless of actual line count for the same
-- uniform-card-height reasoning as the name plate above.
MPAPI.ui_pillar_description_box = function(spec)
	spec = spec or {}
	local nodes = {}
	for _, line in ipairs(spec.lines or {}) do
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
			{ n = G.UIT.T, config = { text = line, scale = 0.32, colour = G.C.WHITE, shadow = true, maxw = spec.maxw or 2.3 } },
		} }
	end
	if spec.caption then
		nodes[#nodes + 1] = small_caption(spec.caption)
	end
	return MPAPI.ui_embossed_box({ minw = spec.minw or 2.4, minh = spec.minh or 0.85, nodes = nodes })
end

-- The common "label row + big value row" stat-box shape. For anything this can't express
-- (multiple side-by-side values, a live-polled/MPAPI.ui_element-wrapped box), build a custom
-- node with MPAPI.ui_embossed_box directly and hand it in as `item.stat_box` instead.
MPAPI.ui_pillar_stat_box = function(spec)
	spec = spec or {}
	return MPAPI.ui_embossed_box({ minw = spec.minw or 2.4, nodes = {
		{ n = G.UIT.R, config = { align = 'cm' }, nodes = {
			{ n = G.UIT.T, config = { text = spec.label, scale = 0.28, colour = G.C.WHITE, shadow = true } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', minh = 0.45 }, nodes = {
			{ n = G.UIT.T, config = { text = tostring(spec.value), scale = 0.55, colour = spec.value_colour or G.C.RED, shadow = true } },
		} },
	} })
end

-----------------------------
-- Row assembly
-----------------------------

local function build_pillar(item, config, tracker)
	if item.icon then
		tracker[#tracker + 1] = item.icon
	end

	local nodes = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = { item.select } },
		item.name_plate,
	}
	if item.icon then
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05, minh = 1.1 }, nodes = {
			{ n = G.UIT.O, config = { object = item.icon } },
		} }
	end
	if item.description then
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { item.description } }
	end
	if item.stat_box then
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { item.stat_box } }
	end
	if item.extra then
		nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { item.extra } }
	end

	return { n = G.UIT.C, config = { align = 'cm', padding = 0.15 }, nodes = { {
		n = G.UIT.R,
		config = { id = item.id, align = 'tm', r = 0.1, padding = 0.05 },
		nodes = { {
			-- align = 'tm' (not 'cm') and a tall minh keep the content stacked at the top and let
			-- the coloured/outlined background itself stretch down to fill the rest of the page,
			-- instead of centering the (shorter) content inside a tall box and leaving empty gaps
			-- above and below it.
			n = G.UIT.R,
			config = {
				align = 'tm', minh = config.pillar_minh or 7.4, r = config.pillar_r or 0.1,
				colour = config.pillar_colour or mix_colours(G.C.BLACK, G.C.L_BLACK, 0.5),
				outline = 1, outline_colour = config.pillar_outline_colour or G.C.L_BLACK,
			},
			nodes = nodes,
		} },
	} } }
end

-- config = {
--   items = { pillar_item, ... },  -- required, ordered; see pillar_item shape in the header
--   pillar_minh, pillar_colour, pillar_outline_colour, pillar_r,  -- optional
--   group_gap = 0.9,   -- spacer width inserted between adjacent items whose `group` differs;
--                       -- no item setting `group` anywhere in the list means no gaps at all
--   root_colour = G.C.CLEAR,
-- }
-- pillar_item = {
--   id, group,             -- optional identifier / grouping key
--   icon,                  -- optional pre-built Love2D drawable, tracked + :remove()'d by :dispose()
--   select,                -- required node (e.g. MPAPI.ui_pillar_select_button{...}, or a fully
--                          -- custom reactive node the caller built itself)
--   name_plate,            -- required node (e.g. MPAPI.ui_pillar_name_plate{...})
--   description, stat_box, extra,  -- optional nodes
-- }
-- Returns { definition, row_node, dispose = function(self) ... end }.
MPAPI.ui_pillar_row = function(config)
	config = config or {}
	local tracker = {}
	local row = {}
	local prev_group = nil
	for _, item in ipairs(config.items or {}) do
		if prev_group ~= nil and item.group ~= prev_group then
			row[#row + 1] = { n = G.UIT.C, config = { minw = config.group_gap or 0.9 }, nodes = {} }
		end
		prev_group = item.group
		row[#row + 1] = build_pillar(item, config, tracker)
	end

	local row_node = { n = G.UIT.R, config = { align = 'cm', padding = 0 }, nodes = row }
	local pr = {
		row_node = row_node,
		definition = {
			n = G.UIT.ROOT,
			config = { align = 'tm', colour = config.root_colour or G.C.CLEAR },
			nodes = { row_node },
		},
	}
	function pr:dispose()
		for _, obj in ipairs(tracker) do
			pcall(function() obj:remove() end)
		end
	end
	return pr
end
