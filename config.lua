return {
	['chat_enabled'] = false,
	['use_custom_server'] = false,
	['custom_server_url'] = '127.0.0.1',
	['custom_server_secure'] = true,
	-- Local dev only: log in through the custom server's Nakama (port
	-- nakama_port on custom_server_url) instead of sending the Steam ticket to
	-- the API. Ignored unless use_custom_server is on.
	['use_nakama_auth'] = false,
	['nakama_port'] = 7350,
	['nakama_server_key'] = 'defaultkey',
	-- Local dev only, needs use_nakama_auth: host lobbies as Nakama matches
	-- (lobby only, no actions or chat yet, so no games).
	['use_nakama_lobbies'] = false,
	-- Local dev only: impersonated logins have no Steam ticket, so sign them
	-- in to Nakama with a device id (needs the server's ALLOW_DEVICE_AUTH).
	['nakama_dev_device_auth'] = false,
}
