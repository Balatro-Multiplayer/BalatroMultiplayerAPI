-- The connection_state view: the table the account UI reads, plus the helpers
-- that keep its status text and display name in sync. Shared connection internals
-- live on MPAPI._internal.conn so the lifecycle and profile files reach the active
-- connection without load-order coupling.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

MPAPI.connection_state = {
	state = MPAPI.ConnectionState.DISCONNECTED,
	status_text = localize('k_status_offline'),
	-- When non-nil, takes precedence over the connection-derived status text so a
	-- mod can surface a transient status (e.g. a matchmaking timer) in the
	-- account panel. Keep overrides short — the panel is fixed-width and long
	-- text forces the whole UIBox to scale down to fit.
	status_override = nil,
	player_id = '',
	display_name = localize('b_retry_connection'),
	steam_name = '',
	discord_name = '',
	is_temp = false,
	use_discord_name = false,
	preferred_joker = 'j_joker',
	privileges = {},
	tos_is_update = false,
	chat_enabled = false,
	chat_blocked = false,
}

C.update_display_name = function()
	if MPAPI.connection_state.state ~= MPAPI.ConnectionState.CONNECTED then
		if MPAPI.connection_state.state == MPAPI.ConnectionState.LOGIN_AVAILABLE then
			MPAPI.connection_state.display_name = localize('b_log_in')
		else
			MPAPI.connection_state.display_name = localize('b_retry_connection')
		end
	elseif C.connection and C.connection.display_name then
		MPAPI.connection_state.display_name = MPAPI.truncate(C.connection.display_name, 20)
	elseif MPAPI.connection_state.steam_name ~= '' then
		MPAPI.connection_state.display_name = MPAPI.connection_state.steam_name
	else
		MPAPI.connection_state.display_name = localize('k_unknown')
	end

	if MPAPI.account_button then
		MPAPI.account_button:update()
	end
	if MPAPI.account_overlay then
		MPAPI.account_overlay:update()
	end
end

C.reset_state_vars = function()
	MPAPI.connection_state.player_id = ''
	MPAPI.connection_state.steam_name = ''
	MPAPI.connection_state.discord_name = ''
	MPAPI.connection_state.is_temp = false
	MPAPI.connection_state.use_discord_name = false
	MPAPI.connection_state.preferred_joker = 'j_joker'
	MPAPI.connection_state.privileges = nil
	MPAPI.connection_state.chat_enabled = false
	MPAPI.connection_state.chat_blocked = false
end

C.set_status_text = function()
	if MPAPI.connection_state.status_override then
		MPAPI.connection_state.status_text = MPAPI.connection_state.status_override
		return
	end
	if MPAPI.connection_state.state == MPAPI.ConnectionState.CONNECTED then
		MPAPI.connection_state.status_text = localize('k_status_connected')
	elseif MPAPI.connection_state.state == MPAPI.ConnectionState.AUTHENTICATING then
		MPAPI.connection_state.status_text = localize('k_status_signing_in')
	elseif MPAPI.connection_state.state == MPAPI.ConnectionState.CONNECTING then
		MPAPI.connection_state.status_text = localize('k_status_connecting')
	else
		MPAPI.connection_state.status_text = localize('k_status_offline')
	end
end

-- Set (text) or clear (nil) the transient status override shown in the account
-- panel. The status text element reads connection_state.status_text live, so the
-- change takes effect on the next frame. Keep text short (see status_override).
function MPAPI.set_connection_status(text)
	-- Whether we are entering or leaving the override (Connected <-> Queueing).
	-- This is the only point the status text width changes; steady timer ticks
	-- keep the same width.
	local shape_changed = (MPAPI.connection_state.status_override == nil) ~= (text == nil)

	MPAPI.connection_state.status_override = text
	C.set_status_text()

	-- On that transition, Balatro's text-fit shrinks the persistent panel and the
	-- reduction accumulates across queue start/stop cycles. Rebuild the panel
	-- fresh so it starts from base scale. The new build already carries the new
	-- text, so the live ref_value never sees a width change to refit. Steady
	-- ticks (same width) update live with no rebuild and no shrink.
	if shape_changed and MPAPI.account_button then
		MPAPI.account_button:update()
	end
end
