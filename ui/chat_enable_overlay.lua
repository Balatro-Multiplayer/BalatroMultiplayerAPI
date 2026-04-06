-- Birthdate picker for age verification.
-- The birthdate is NEVER sent to the server — only the boolean result is stored.

local MONTH_NAMES = {
	'January', 'February', 'March', 'April', 'May', 'June',
	'July', 'August', 'September', 'October', 'November', 'December',
}

-- Backing store for selections
local _sel_data = {
	month = '1',
	day   = '1',
	year  = tostring(os.date('*t').year),
}

-- Whether the user has changed at least one dropdown since the overlay opened
local _changed = false

-- Proxy table: writes set _changed and schedule an overlay refresh next frame.
-- The update must be deferred — calling it synchronously inside the dropdown's
-- selection handler destroys the UI tree while the dropdown is still executing.
local _sel = setmetatable({}, {
	__index = function(_, k) return _sel_data[k] end,
	__newindex = function(_, k, v)
		if _sel_data[k] ~= v then
			_sel_data[k] = v
			_changed = true
			G.E_MANAGER:add_event(Event({
				blockable = false,
				blocking = false,
				func = function()
					if MPAPI.chat_enable_overlay then
						MPAPI.chat_enable_overlay:update()
					end
					return true
				end,
			}))
		end
	end,
})

local _submitting = false

-----------------------------
-- OPTION LISTS
-----------------------------

local function month_options()
	local opts = {}
	for i = 1, 12 do opts[#opts + 1] = tostring(i) end
	return opts
end

local function day_options()
	local opts = {}
	for d = 1, 31 do opts[#opts + 1] = tostring(d) end
	return opts
end

local function year_options()
	local now = os.date('*t').year
	local opts = {}
	for y = now, now - 100, -1 do
		opts[#opts + 1] = tostring(y)
	end
	return opts
end

-----------------------------
-- UI BUILDER
-----------------------------

local create_UIBox_chat_enable_overlay = function()
	local notice_lines = {
		localize('k_chat_enable_notice_1'),
		localize('k_chat_enable_notice_2'),
	}

	local submit_disabled    = _submitting or not _changed
	local submit_colour      = submit_disabled and G.C.UI.BACKGROUND_INACTIVE or G.C.GREEN
	local submit_text_colour = submit_disabled and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT
	local submit_config = {
		align = 'cm', padding = 0.15, minw = 5, minh = 0.7,
		r = 0.1, colour = submit_colour, shadow = true,
	}
	if not submit_disabled then
		submit_config.hover  = true
		submit_config.button = 'mpapi_chat_submit_birthdate'
	end

	local function picker_col(label_key, dropdown_node)
		return {
			n = G.UIT.C,
			config = { align = 'cm', padding = 0.08 },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.04 },
					nodes = {
						{ n = G.UIT.T, config = {
							text = localize(label_key),
							scale = 0.35, colour = G.C.UI.TEXT_LIGHT,
						} },
					},
				},
				dropdown_node,
			},
		}
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 9, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				-- Title
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = {
							text = localize('k_chat_enable_title'),
							scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true,
						} },
					},
				},
				-- Notice lines
				(function()
					local rows = {}
					for _, line in ipairs(notice_lines) do
						rows[#rows + 1] = {
							n = G.UIT.R,
							config = { align = 'cm', padding = 0.04 },
							nodes = {
								{ n = G.UIT.T, config = {
									text = line, scale = 0.32, colour = G.C.UI.TEXT_LIGHT,
								} },
							},
						}
					end
					return { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
						{ n = G.UIT.C, config = { align = 'cm' }, nodes = rows },
					} }
				end)(),
				-- Spacer
				{ n = G.UIT.R, config = { minh = 0.15 } },
				-- Pickers row: Month | Day | Year
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						picker_col('k_chat_birth_month', SMODS.GUI.dropdown_select({
							options           = month_options(),
							ref_table         = _sel,
							ref_value         = 'month',
							init_value        = _sel.month,
							minw              = 3,
							no_unselect       = true,
							close_on_select   = true,
							max_menu_h        = 4,
							colour            = MPAPI.C.MP_EDITION,
							display_choice_func = function(opt)
								return MONTH_NAMES[tonumber(opt)] or opt
							end,
						})),
						picker_col('k_chat_birth_day', SMODS.GUI.dropdown_select({
							options         = day_options(),
							ref_table       = _sel,
							ref_value       = 'day',
							init_value      = _sel.day,
							minw            = 1.5,
							no_unselect     = true,
							close_on_select = true,
							max_menu_h      = 4,
							colour          = MPAPI.C.MP_EDITION,
						})),
						picker_col('k_chat_birth_year', SMODS.GUI.dropdown_select({
							options         = year_options(),
							ref_table       = _sel,
							ref_value       = 'year',
							init_value      = _sel.year,
							minw            = 2,
							no_unselect     = true,
							close_on_select = true,
							max_menu_h      = 4,
							colour          = MPAPI.C.MP_EDITION,
						})),
					},
				},
				-- Privacy notice
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.04 },
					nodes = {
						{ n = G.UIT.T, config = {
							text = localize('k_chat_birth_privacy_1'),
							scale = 0.28, colour = G.C.UI.TEXT_INACTIVE,
						} },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.04 },
					nodes = {
						{ n = G.UIT.T, config = {
							text = localize('k_chat_birth_privacy_2'),
							scale = 0.28, colour = G.C.UI.TEXT_INACTIVE,
						} },
					},
				},
				-- Spacer
				{ n = G.UIT.R, config = { minh = 0.1 } },
				-- Submit button
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{
							n = G.UIT.C,
							config = submit_config,
							nodes = {
								{ n = G.UIT.T, config = {
									text = localize('b_chat_submit_age'),
									scale = 0.45, colour = submit_text_colour, shadow = true,
								} },
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_chat_submit_birthdate = function(e)
	if _submitting or not _changed then return end

	local year  = tonumber(_sel.year)
	local month = tonumber(_sel.month)
	local day   = tonumber(_sel.day)

	if not year or not month or not day then
		MPAPI.sendWarnMessage('[chat] Invalid birthdate selection')
		return
	end

	_submitting = true
	if MPAPI.chat_enable_overlay then
		MPAPI.chat_enable_overlay:update()
	end

	MPAPI._internal.enable_chat(year, month, day, function(err, data)
		_submitting = false
		if err then
			MPAPI.sendWarnMessage('[chat] Age verification failed: ' .. tostring(err))
			if MPAPI.chat_enable_overlay then
				MPAPI.chat_enable_overlay:update()
			end
			return
		end

		-- If verified, also turn on the client-side toggle
		if MPAPI.connection_state.chat_enabled then
			MPAPI._internal.config_set('chat_enabled', true)
			-- Activate chat in the current lobby without requiring a rejoin
			MPAPI.chat.on_chat_enabled()
		end

		G.FUNCS.exit_overlay_menu()

		if MPAPI.account_overlay then
			MPAPI.account_overlay:update()
		end

		if MPAPI.connection_state.chat_blocked then
			MPAPI.chat.addMessage(localize('k_chat_age_blocked'), { 1, 0.4, 0.4 })
		end
	end)
end

G.FUNCS.mpapi_open_chat_enable = function(e)
	_submitting = false
	_changed = false
	-- Reset selections to defaults each time the overlay opens
	local now = os.date('*t').year
	_sel_data.month = '1'
	_sel_data.day   = '1'
	_sel_data.year  = tostring(now)
	MPAPI.chat_enable_overlay:as_overlay()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.chat_enable_overlay = MPAPI.ui_element(create_UIBox_chat_enable_overlay)
