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
}
