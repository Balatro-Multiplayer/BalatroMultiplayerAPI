-- Module-level state
local _account_blocked = false
local _is_update = false
local _pending_show = false

-- Birthdate picker state (deferred-proxy pattern: __newindex triggers overlay rebuild)
local _sel_data = {
	month = '1',
	day   = '1',
	year  = tostring(os.date('*t').year),
}
local _date_changed = false

local _sel = setmetatable({}, {
	__index    = function(_, k) return _sel_data[k] end,
	__newindex = function(_, k, v)
		if _sel_data[k] ~= v then
			_sel_data[k] = v
			_date_changed = true
			G.E_MANAGER:add_event(Event({
				blockable = false,
				blocking  = false,
				func = function()
					if MPAPI.tos_overlay then MPAPI.tos_overlay:update() end
					return true
				end,
			}))
		end
	end,
})

-- Toggle ref table for the agreement checkbox.
-- create_toggle reads ref_table[ref_value] every frame via G.FUNCS.toggle,
-- so the visual state stays correct across overlay rebuilds.
local _agreed_table = { value = false }

local MONTH_NAMES = {
	'January', 'February', 'March', 'April', 'May', 'June',
	'July', 'August', 'September', 'October', 'November', 'December',
}

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
	for y = now, now - 120, -1 do opts[#opts + 1] = tostring(y) end
	return opts
end

local function compute_age()
	local year  = tonumber(_sel.year)
	local month = tonumber(_sel.month)
	local day   = tonumber(_sel.day)
	if not year or not month or not day then return nil end
	local now = os.date('*t')
	local age = now.year - year
	if now.month < month or (now.month == month and now.day < day) then
		age = age - 1
	end
	return age
end

-----------------------------
-- UI HELPERS
-----------------------------

local function section_label(text_key)
	return {
		n = G.UIT.R,
		config = { align = 'lm', padding = 0.05 },
		nodes = {
			{ n = G.UIT.T, config = { text = localize(text_key), scale = 0.3, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		},
	}
end

local function hint_text(text_key)
	return {
		n = G.UIT.R,
		config = { align = 'lm', padding = 0.03 },
		nodes = {
			{ n = G.UIT.T, config = { text = localize(text_key), scale = 0.27, colour = G.C.UI.TEXT_LIGHT } },
		},
	}
end

local function bullet_row(text_key)
	return {
		n = G.UIT.R,
		config = { align = 'lm', padding = 0.03 },
		nodes = {
			{ n = G.UIT.T, config = { text = '- ', scale = 0.28, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { text = localize(text_key), scale = 0.28, colour = G.C.UI.TEXT_LIGHT } },
		},
	}
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
					{ n = G.UIT.T, config = { text = localize(label_key), scale = 0.28, colour = G.C.UI.TEXT_LIGHT } },
				},
			},
			dropdown_node,
		},
	}
end

-----------------------------
-- UI FUNCTIONS
-----------------------------

local create_UIBox_tos_overlay = function()
	-- Blocked state — no button, overlay back button dismisses without disconnecting.
	if _account_blocked then
		local contents = {
			{
				n = G.UIT.C,
				config = { align = 'cm', minw = 7, padding = 0.3, r = 0.1, colour = G.C.CLEAR },
				nodes = {
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.15 },
						nodes = {
							{ n = G.UIT.T, config = { text = localize('k_tos_blocked_title'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						},
					},
				},
			},
		}
		return create_UIBox_generic_options({ snap_back = false, contents = contents })
	end

	-- TOS update flow — existing user, no birthdate needed.
	if _is_update then
		local contents = {
			{
				n = G.UIT.C,
				config = { align = 'cm', minw = 7, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
				nodes = {
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.1 },
						nodes = {
							{ n = G.UIT.T, config = { text = localize('k_tos_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						},
					},
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.05 },
						nodes = {
							{ n = G.UIT.T, config = { text = localize('k_tos_update_1'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
						},
					},
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.05 },
						nodes = {
							{ n = G.UIT.T, config = { text = localize('k_tos_update_2'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
						},
					},
					{ n = G.UIT.R, config = { minh = 0.15 } },
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = {
							{
								n = G.UIT.C,
								config = { align = 'cm', padding = 0.1, minw = 5, minh = 0.65, r = 0.1, hover = true, colour = G.C.BLUE, button = 'mpapi_view_notice', shadow = true },
								nodes = {
									{ n = G.UIT.T, config = { text = localize('b_view_notice'), scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
								},
							},
						},
					},
					{ n = G.UIT.R, config = { minh = 0.15 } },
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = {
							{
								n = G.UIT.C,
								config = { align = 'cm', padding = 0.1, minw = 4, minh = 0.65, r = 0.1, hover = true, colour = G.C.GREEN, button = 'mpapi_tos_accept_update', shadow = true },
								nodes = {
									{ n = G.UIT.T, config = { text = localize('b_i_accept'), scale = 0.42, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
								},
							},
						},
					},
				},
			},
		}
		return create_UIBox_generic_options({ snap_back = false, contents = contents })
	end

	-- New account signup flow
	local accept_ready       = _date_changed and _agreed_table.value
	local accept_colour      = accept_ready and G.C.GREEN or G.C.UI.BACKGROUND_INACTIVE
	local accept_text_colour = accept_ready and G.C.UI.TEXT_LIGHT or G.C.UI.TEXT_INACTIVE
	local accept_config = {
		align = 'cm', padding = 0.1, minw = 4.5, minh = 0.65,
		r = 0.1, colour = accept_colour, shadow = true,
	}
	if accept_ready then
		accept_config.hover  = true
		accept_config.button = 'mpapi_tos_accept'
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 7.5, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				-- Title
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.08 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_tos_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				-- Subtitle
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.04 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_tos_first_time_1'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.12 } },
				-- Birthday section
				section_label('k_tos_birth_section'),
				hint_text('k_tos_birth_hint'),
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						picker_col('k_chat_birth_month', SMODS.GUI.dropdown_select({
							options             = month_options(),
							ref_table           = _sel,
							ref_value           = 'month',
							init_value          = _sel.month,
							minw                = 2.3,
							no_unselect         = true,
							close_on_select     = true,
							max_menu_h          = 4,
							colour              = MPAPI.C.MP_EDITION,
							display_choice_func = function(opt) return MONTH_NAMES[tonumber(opt)] or opt end,
						})),
						picker_col('k_chat_birth_day', SMODS.GUI.dropdown_select({
							options         = day_options(),
							ref_table       = _sel,
							ref_value       = 'day',
							init_value      = _sel.day,
							minw            = 1.1,
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
							minw            = 1.6,
							no_unselect     = true,
							close_on_select = true,
							max_menu_h      = 4,
							colour          = MPAPI.C.MP_EDITION,
						})),
					},
				},
				{ n = G.UIT.R, config = { minh = 0.1 } },
				-- Agreement section
				section_label('k_tos_agreement_section'),
				bullet_row('k_tos_bullet_1'),
				bullet_row('k_tos_bullet_2'),
				bullet_row('k_tos_bullet_3'),
				{ n = G.UIT.R, config = { minh = 0.08 } },
				-- View notice button
				{
					n = G.UIT.R,
					config = { align = 'lm' },
					nodes = {
						{
							n = G.UIT.C,
							config = { align = 'cm', padding = 0.08, minw = 4.5, minh = 0.6, r = 0.1, hover = true, colour = G.C.BLUE, button = 'mpapi_view_notice', shadow = true },
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_view_notice'), scale = 0.35, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
							},
						},
					},
				},
				{ n = G.UIT.R, config = { minh = 0.06 } },
				-- Checkbox using create_toggle (func = 'toggle' re-syncs visual state every frame)
				create_toggle({
					label       = localize('k_tos_agree'),
					ref_table   = _agreed_table,
					ref_value   = 'value',
					w           = 5.2,
					label_scale = 0.3,
					active_colour   = G.C.GREEN,
					inactive_colour = G.C.BLACK,
					callback    = function()
						if MPAPI.tos_overlay then MPAPI.tos_overlay:update() end
					end,
				}),
				{ n = G.UIT.R, config = { minh = 0.1 } },
				-- Create Account button
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{
							n = G.UIT.C,
							config = accept_config,
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_create_account'), scale = 0.42, colour = accept_text_colour, shadow = true } },
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = false, contents = contents })
end

-----------------------------
-- INTERNAL API
-----------------------------

local function _do_show()
	_pending_show = false
	MPAPI.sendDebugMessage('[tos] _do_show')
	MPAPI.tos_overlay:as_overlay()
end

MPAPI._internal.show_tos_overlay = function(is_update)
	_is_update             = is_update or false
	_date_changed          = false
	_agreed_table.value    = false
	if not _account_blocked then
		local now = os.date('*t').year
		_sel_data.month = '1'
		_sel_data.day   = '1'
		_sel_data.year  = tostring(now)
	end

	if G.STATE == G.STATES.MENU then
		_do_show()
	else
		_pending_show = true
	end
end

MPAPI._internal.flush_tos_overlay = function()
	if _pending_show then
		_do_show()
	end
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_tos_accept = function(e)
	if not (_date_changed and _agreed_table.value) then return end

	local age = compute_age()

	if age ~= nil and age < 13 then
		_account_blocked = true
		if MPAPI.tos_overlay then MPAPI.tos_overlay:update() end
		return
	end

	local chat_eligible = age ~= nil and age >= 16

	G.FUNCS.exit_overlay_menu()
	local conn = MPAPI.get_connection()
	if conn then
		conn:accept_tos(chat_eligible)
	end
end

G.FUNCS.mpapi_tos_accept_update = function(e)
	G.FUNCS.exit_overlay_menu()
	local conn = MPAPI.get_connection()
	if conn then
		conn:accept_tos(nil)
	end
end

G.FUNCS.mpapi_view_notice = function(e)
	love.system.openURL('https://balatromp.com/notice')
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.tos_overlay = MPAPI.ui_element(create_UIBox_tos_overlay)
