-- Report-a-player overlay: picking a reason from a fixed 5-way taxonomy is the
-- entire in-game flow (no text box -- Balatro's own text input isn't a
-- reasonable place to type out an incident, per the design doc). Opened from
-- ui/player_mute_overlay.lua's "Report Player" button. Modeled on
-- BalatroMultiplayerPvP's ui/pvp_main_menu.lua "Create Lobby" grid-of-buttons
-- overlay, extended from 2x2 to 2-2-1 for the fifth reason.
local _target_id = nil
local _target_name = nil
local _lobby_code = nil
local _submitting = false
local _result_report_id = nil

local REASONS = {
	{ type = 'cheating', label_key = 'k_report_cheating' },
	{ type = 'chat_abuse', label_key = 'k_report_chat_abuse' },
	{ type = 'griefing', label_key = 'k_report_griefing' },
	{ type = 'inappropriate_username', label_key = 'k_report_inappropriate_username' },
	{ type = 'other', label_key = 'k_report_other' },
}

-- Raw node (not the UIBox_button helper) so ref_table reliably threads a
-- custom payload through to the button handler's e.config.ref_table --
-- confirmed working via ui/main_menu.lua's mod_button (config.ref_table /
-- G.FUNCS.mpapi_mod_button reading e.config.ref_table.mod_id).
local function reason_button(reason)
	local config = {
		align = 'cm', padding = 0.1, minw = 3.2, minh = 1.3, r = 0.1,
		colour = _submitting and G.C.UI.BACKGROUND_INACTIVE or G.C.RED,
		shadow = true,
	}
	if not _submitting then
		config.hover = true
		config.button = 'mpapi_report_player_reason'
		config.ref_table = reason
	end

	return {
		n = G.UIT.C,
		config = { align = 'cm', padding = 0.08 },
		nodes = {
			{ n = G.UIT.C, config = config, nodes = {
				{ n = G.UIT.T, config = {
					text = localize(reason.label_key), scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true,
				} },
			} },
		},
	}
end

local create_UIBox_player_report_overlay = function()
	local contents

	if _result_report_id then
		contents = {
			{
				n = G.UIT.C,
				config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
				nodes = {
					{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
						{ n = G.UIT.T, config = { text = localize('k_report_submitted'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					} },
				},
			},
		}
	else
		contents = {
			{
				n = G.UIT.C,
				config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
				nodes = {
					{
						n = G.UIT.R,
						config = { align = 'cm', padding = 0.1 },
						nodes = {
							{ n = G.UIT.T, config = { text = localize('k_report_player') .. ': ' .. (_target_name or ''), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						},
					},
					{ n = G.UIT.R, config = { minh = 0.15 } },
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = { reason_button(REASONS[1]), reason_button(REASONS[2]) },
					},
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = { reason_button(REASONS[3]), reason_button(REASONS[4]) },
					},
					{
						n = G.UIT.R,
						config = { align = 'cm' },
						nodes = { reason_button(REASONS[5]) },
					},
				},
			},
		}
	end

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

G.FUNCS.mpapi_report_player_reason = function(e)
	if _submitting or not _target_id or not _lobby_code then
		return
	end
	local reason = e.config.ref_table
	if not reason then
		return
	end

	_submitting = true
	if MPAPI.player_report_overlay then MPAPI.player_report_overlay:update() end

	MPAPI._internal.report_player(_lobby_code, _target_id, reason.type, nil, function(err, data)
		_submitting = false
		if err then
			MPAPI.sendWarnMessage('[report] Submission failed: ' .. tostring(err))
			if MPAPI.player_report_overlay then MPAPI.player_report_overlay:update() end
			return
		end

		_result_report_id = data and data.reportId

		-- §15.5: hand the submitting player a link to their scoped status page.
		if _result_report_id then
			local conn = MPAPI._internal.conn and MPAPI._internal.conn.connection
			local base_url = conn and conn.api and conn.api.base_url
			if base_url then
				local link = base_url .. '/reports/' .. tostring(_result_report_id)
				pcall(function()
					if love.system and love.system.setClipboardText then
						love.system.setClipboardText(link)
					end
				end)
				MPAPI.chat.addMessage('[report] ' .. link .. ' (copied to clipboard)', { 1, 0.65, 0 })
			end
		end

		if MPAPI.player_report_overlay then MPAPI.player_report_overlay:update() end
	end)
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.player_report_overlay = MPAPI.ui_element(create_UIBox_player_report_overlay)

-- Called from ui/player_mute_overlay.lua's "Report Player" button with the
-- clicked player's id/display name. Resolves the current lobby code itself --
-- the only match-context identifier available client-side (the server
-- resolves lobbyCode -> the actual match/runId at submission time).
function MPAPI.open_player_report_overlay(player_id, player_name)
	_target_id = player_id
	_target_name = player_name or 'Unknown'
	local lobby = MPAPI.get_current_lobby()
	_lobby_code = lobby and lobby.code or nil
	_submitting = false
	_result_report_id = nil
	MPAPI.player_report_overlay:as_overlay()
end
