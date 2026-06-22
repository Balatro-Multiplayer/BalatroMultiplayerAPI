local _submitting = false

local create_UIBox_chat_enable_overlay = function()
	local submit_colour      = _submitting and G.C.UI.BACKGROUND_INACTIVE or G.C.GREEN
	local submit_text_colour = _submitting and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT
	local submit_config = {
		align = 'cm', padding = 0.15, minw = 5, minh = 0.7,
		r = 0.1, colour = submit_colour, shadow = true,
	}
	if not _submitting then
		submit_config.hover  = true
		submit_config.button = 'mpapi_chat_enable_confirm'
	end

	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_enable_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_chat_enable_desc'), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = submit_config, nodes = {
							{ n = G.UIT.T, config = { text = localize('k_chat_enable_title'), scale = 0.45, colour = submit_text_colour, shadow = true } },
						} },
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

G.FUNCS.mpapi_chat_enable_confirm = function(e)
	if _submitting then return end
	_submitting = true
	if MPAPI.chat_enable_overlay then MPAPI.chat_enable_overlay:update() end

	MPAPI._internal.enable_chat(function(err, data)
		_submitting = false
		if err then
			MPAPI.sendWarnMessage('[chat] Enable chat failed: ' .. tostring(err))
			if MPAPI.chat_enable_overlay then MPAPI.chat_enable_overlay:update() end
			return
		end

		if MPAPI.connection_state.chat_enabled then
			MPAPI._internal.config_set('chat_enabled', true)
			MPAPI.chat.on_chat_enabled()
		end

		G.FUNCS.exit_overlay_menu()

		if MPAPI.account_overlay then MPAPI.account_overlay:update() end

		if MPAPI.connection_state.chat_blocked then
			MPAPI.chat.addMessage(localize('k_chat_age_blocked'), { 1, 0.4, 0.4 })
		end
	end)
end

G.FUNCS.mpapi_open_chat_enable = function(e)
	_submitting = false
	MPAPI.chat_enable_overlay:as_overlay()
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.chat_enable_overlay = MPAPI.ui_element(create_UIBox_chat_enable_overlay)
