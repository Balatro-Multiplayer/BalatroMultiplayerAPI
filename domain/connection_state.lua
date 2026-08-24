MPAPI.ConnectionState = {
	DISCONNECTED = 'disconnected',
	TOS_REQUIRED = 'tos_required',
	AUTHENTICATING = 'authenticating',
	CONNECTING = 'connecting',
	CONNECTED = 'connected',
	-- An unsolicited MQTT drop mid-session: distinct from CONNECTING (a fresh
	-- connect attempt) so the account panel can show "Reconnecting..." rather
	-- than silently falling back to "Offline" while connection:_attempt_mqtt_reconnect
	-- redials with the still-cached credentials (see networking/connection.lua).
	RECONNECTING = 'reconnecting',
}
