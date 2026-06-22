-----------------------------
-- Generic leaderboard overlay
-----------------------------
-- A reusable, paginated leaderboard overlay with gamemode tabs and an own-rank
-- footer, styled like a base-game Poker Hands list. The consuming mod supplies the
-- tabs, the columns (after rank + player name), and a fetch function; pagination,
-- tab switching, self-row detection and the overlay plumbing live here.

local _lb_counter = 0

local function resolve(v)
	if type(v) == 'function' then
		return v()
	end
	return v
end

-- config:
--   tabs     list of { key, label, colour }      gamemode tabs (first is default)
--   columns  list of value columns rendered after the player name, each:
--              { header, header_colour?, colour, width, value = function(entry) -> string }
--            header may be a string or a function (resolved at render, so localized
--            headers can be passed safely).
--   fetch    function(tab_key, cb) -> calls cb(err, data); data = { entries, playerEntry }
--            entries are { rank, displayName, playerId, ... } sorted by rank.
--   per_page entries shown per page (default 10)
--   web_url  optional URL for a "view full leaderboards" button
--   web_label / self_label / empty_text / loading_text  display string overrides
--   rank_width / name_width / list_minh  layout overrides
--
-- Returns a controller with :open(tab_key, page) and :current_tab(). Button G.FUNCS
-- handlers are registered per instance under a unique id.
MPAPI.ui_leaderboard = function(config)
	config = config or {}
	_lb_counter = _lb_counter + 1
	local uid = 'mpapi_lb_' .. _lb_counter

	local tabs = config.tabs or {}
	local columns = config.columns or {}
	local per_page = config.per_page or 10
	local fetch = config.fetch
	local web_url = config.web_url
	local web_label = config.web_label or 'View full leaderboards'
	local self_label = config.self_label or 'You'
	local empty_text = config.empty_text or 'No ranked players yet.'
	local loading_text = config.loading_text or 'Loading...'

	local rank_w = config.rank_width or 0.55
	local name_w = config.name_width or 2.6

	-- Reserved heights so the layout stays the same size with or without data: the
	-- entry list always reserves a full page's worth of rows, and the pager row is
	-- reserved while loading. This stops tab switches from flickering as data loads.
	local LIST_MINH = config.list_minh or 4.7
	local PAGER_MINH = 0.6

	local lb = {}
	local _data = nil
	local _tab = tabs[1] and tabs[1].key
	local _page = 1
	local element

	local function tab_colour(key)
		for _, t in ipairs(tabs) do
			if t.key == key then
				return t.colour or G.C.WHITE
			end
		end
		return G.C.WHITE
	end

	-- A value box mirroring the chips/mult readouts on a base-game Poker Hands row.
	-- The 0.03 wrapper padding spaces the boxes apart.
	local function value_box(text, box_colour, minw)
		return {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.03 },
			nodes = {
				{
					n = G.UIT.C,
					config = { align = 'cm', minw = minw, minh = 0.42, padding = 0.03, r = 0.07, colour = box_colour, emboss = 0.04 },
					nodes = {
						{ n = G.UIT.T, config = { text = text, scale = 0.3, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
			},
		}
	end

	-- A header label cell using the same column width + spacing as value_box so the
	-- header lines up exactly with the rows beneath it.
	local function header_cell(text, text_colour, minw, align)
		return {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.03 },
			nodes = {
				{ n = G.UIT.C, config = { align = align or 'cm', minw = minw }, nodes = {
					{ n = G.UIT.T, config = { text = text, scale = 0.28, colour = text_colour } },
				} },
			},
		}
	end

	-- One entry built like a base-game Poker Hands row: a coloured rank badge (the
	-- level badge), the player name (the hand name), then a value box per column.
	-- opts.is_self tints the row; opts.name_override replaces the displayed name
	-- (used by the "You" footer).
	local function entry_row(entry, accent, opts)
		opts = opts or {}
		local row_colour = opts.is_self and { 0.18, 0.45, 0.20, 1 } or darken(G.C.JOKER_GREY, 0.1)
		local name_colour = opts.is_self and G.C.WHITE or G.C.UI.TEXT_LIGHT

		local nodes = {
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.02 }, nodes = {
				{ n = G.UIT.C, config = { align = 'cm', minw = rank_w, minh = 0.42, r = 0.07, colour = accent, emboss = 0.04 }, nodes = {
					{ n = G.UIT.T, config = { text = '#' .. tostring(entry.rank), scale = 0.3, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
				} },
			} },
			{ n = G.UIT.C, config = { align = 'cm', padding = 0.03 }, nodes = {
				{ n = G.UIT.C, config = { align = 'lm', minw = name_w, maxw = name_w }, nodes = {
					{ n = G.UIT.T, config = { text = opts.name_override or entry.displayName or '?', scale = 0.32, colour = name_colour } },
				} },
			} },
		}
		for _, col in ipairs(columns) do
			nodes[#nodes + 1] = value_box(col.value(entry), col.colour, col.width)
		end

		return {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.012, r = 0.08, colour = row_colour, emboss = 0.04 },
			nodes = nodes,
		}
	end

	local function web_button_row()
		return {
			n = G.UIT.R,
			config = { align = 'cm', padding = 0.05 },
			nodes = {
				UIBox_button({
					button = uid .. '_web',
					label = { web_label },
					colour = G.C.BLUE,
					minw = 4.5,
					minh = 0.5,
					scale = 0.32,
				}),
			},
		}
	end

	-- Loading / empty states reserve a full page's height (plus the pager row) so
	-- switching tabs does not collapse the overlay and flicker.
	local function status_block(rows, text)
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', minh = LIST_MINH }, nodes = {
			{ n = G.UIT.T, config = { text = text, scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', minh = PAGER_MINH }, nodes = {} }
	end

	local function build_content()
		local rows = {}

		-- Tab buttons
		local tab_nodes = {}
		for _, t in ipairs(tabs) do
			local is_active = t.key == _tab
			tab_nodes[#tab_nodes + 1] = {
				n = G.UIT.C,
				config = { align = 'cm', padding = 0.05 },
				nodes = {
					UIBox_button({
						button = uid .. '_tab_' .. t.key,
						label = { t.label },
						colour = is_active and (t.colour or G.C.GREY) or G.C.GREY,
						minw = 3.2,
						minh = 0.5,
						scale = 0.35,
					}),
				},
			}
		end
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = tab_nodes }

		-- Header is always present so the layout height is stable across states.
		local header_nodes = {
			header_cell('#', G.C.UI.TEXT_INACTIVE, rank_w),
			header_cell('Player', G.C.UI.TEXT_INACTIVE, name_w, 'lm'),
		}
		for _, col in ipairs(columns) do
			header_nodes[#header_nodes + 1] = header_cell(resolve(col.header) or '', col.header_colour or G.C.UI.TEXT_INACTIVE, col.width)
		end
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = header_nodes }

		if not _data then
			status_block(rows, loading_text)
			if web_url then
				rows[#rows + 1] = web_button_row()
			end
			return rows
		end

		local entries = _data.entries or {}

		if #entries == 0 then
			status_block(rows, empty_text)
		else
			local accent = tab_colour(_tab)

			local conn = MPAPI.get_connection()
			local own_id = conn and conn.player_id

			-- Find the player's own row anywhere in the full list (for the footer),
			-- independent of the server-provided playerEntry.
			local own_entry = nil
			if own_id then
				for i = 1, #entries do
					if entries[i].playerId == own_id then
						own_entry = entries[i]
						break
					end
				end
			end

			-- Clamp the page and slice this page's entries out of the full list.
			local total_pages = math.max(1, math.ceil(#entries / per_page))
			_page = math.max(1, math.min(_page, total_pages))
			local first = (_page - 1) * per_page + 1
			local last = math.min(first + per_page - 1, #entries)

			-- Build this page's rows into a single column so they stack flush.
			-- create_UIBox_generic_options adds spacing between each top-level content
			-- row, so grouping the entries under one node removes the per-row gaps.
			local list_nodes = {}
			local own_on_page = false
			for i = first, last do
				local entry = entries[i]
				local is_self = own_id and (entry.playerId == own_id)
				if is_self then own_on_page = true end
				list_nodes[#list_nodes + 1] = entry_row(entry, accent, { is_self = is_self })
			end

			-- Own rank footer: shown right below this page's rows when the player has a
			-- ranked row that is not on the current page. Prefer the client-side
			-- own_entry; fall back to the server's playerEntry (covers ranks beyond the
			-- fetched list).
			local footer = own_entry or _data.playerEntry
			if footer and not own_on_page then
				list_nodes[#list_nodes + 1] = { n = G.UIT.R, config = { align = 'cm', minh = 0.08 }, nodes = {} }
				list_nodes[#list_nodes + 1] = entry_row(footer, accent, { is_self = true, name_override = self_label })
			end

			rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm' }, nodes = {
				{ n = G.UIT.C, config = { align = 'tm', minh = LIST_MINH }, nodes = list_nodes },
			} }

			-- Pagination controls (only when there is more than one page).
			if total_pages > 1 then
				rows[#rows + 1] = {
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
							UIBox_button({ button = uid .. '_prev', label = { '<' }, colour = _page > 1 and accent or G.C.GREY, minw = 0.7, minh = 0.5, scale = 0.4 }),
						} },
						{ n = G.UIT.C, config = { align = 'cm', minw = 1.8 }, nodes = {
							{ n = G.UIT.T, config = { text = 'Page ' .. _page .. ' / ' .. total_pages, scale = 0.34, colour = G.C.UI.TEXT_LIGHT } },
						} },
						{ n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
							UIBox_button({ button = uid .. '_next', label = { '>' }, colour = _page < total_pages and accent or G.C.GREY, minw = 0.7, minh = 0.5, scale = 0.4 }),
						} },
					},
				}
			end
		end

		if web_url then
			rows[#rows + 1] = web_button_row()
		end

		return rows
	end

	-- Wrapped in an MPAPI.ui_element so page/tab switches swap the contents in-place
	-- (via :update()) rather than closing and reopening the overlay.
	element = MPAPI.ui_element(function()
		return create_UIBox_generic_options({ contents = build_content() })
	end)

	-- Fetch the current tab's data and refresh in place. Stale responses (the user
	-- switched tabs meanwhile) are ignored.
	local function do_fetch()
		if not fetch then
			return
		end
		local tab = _tab
		fetch(tab, function(err, data)
			if err then
				MPAPI.sendWarnMessage('[leaderboard] fetch error: ' .. tostring(err))
				return
			end
			if _tab ~= tab then
				return
			end
			_data = data
			element:update()
		end)
	end

	function lb:open(tab_key, page)
		_tab = tab_key or _tab or (tabs[1] and tabs[1].key)
		_page = page or 1
		_data = nil
		element:as_overlay()
		do_fetch()
	end

	function lb:current_tab()
		return _tab
	end

	-- Switch tabs: reset to the first page and reopen a fresh overlay so the popup
	-- animation covers the data load, then refetch. (Page changes stay inline via
	-- :update(); only tab switches reopen.)
	local function switch_tab(tab_key)
		if _tab == tab_key then
			return
		end
		_tab = tab_key
		_page = 1
		_data = nil
		element:as_overlay()
		do_fetch()
	end

	-- Per-instance button handlers.
	for _, t in ipairs(tabs) do
		G.FUNCS[uid .. '_tab_' .. t.key] = function()
			switch_tab(t.key)
		end
	end
	G.FUNCS[uid .. '_prev'] = function()
		if _page > 1 then
			_page = _page - 1
			element:update()
		end
	end
	G.FUNCS[uid .. '_next'] = function()
		local total = _data and #(_data.entries or {}) or 0
		local total_pages = math.max(1, math.ceil(total / per_page))
		if _page < total_pages then
			_page = _page + 1
			element:update()
		end
	end
	if web_url then
		G.FUNCS[uid .. '_web'] = function()
			love.system.openURL(web_url)
		end
	end

	lb.element = element
	lb.id = uid
	return lb
end
