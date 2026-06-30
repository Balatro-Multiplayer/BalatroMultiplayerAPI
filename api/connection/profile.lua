-- Account/profile operations that round-trip to the server: discord linking,
-- display-name preference, preferred joker, and chat enablement.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

local function require_connected(callback)
	local conn = C.connection
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return nil
	end
	if not conn.jwt_token then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NO_TOKEN, 'No JWT token'), nil)
		return nil
	end
	return conn
end

MPAPI._internal.get_discord_link_url = function(callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end
	conn.api:get_discord_link_url(conn.jwt_token, callback)
end

MPAPI._internal.set_use_discord_name = function(value, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:set_display_name_pref(conn.jwt_token, value, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.display_name = data.player.displayName or conn.steam_name
			conn.use_discord_name = data.player.useDiscordName or false
		end
		MPAPI.connection_state.use_discord_name = conn.use_discord_name

		C.update_display_name()

		callback(nil, data)
	end)
end

MPAPI._internal.set_preferred_joker = function(value, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:set_preferred_joker(conn.jwt_token, value, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.preferred_joker = data.player.preferredJoker or 'j_joker'
		end
		MPAPI.connection_state.preferred_joker = conn.preferred_joker

		callback(nil, data)
	end)
end

MPAPI._internal.unlink_discord = function(callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:unlink_discord(conn.jwt_token, callback)
end

MPAPI._internal.enable_chat = function(callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:enable_chat(conn.jwt_token, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if data.player then
			conn.chat_enabled = data.player.chatEnabled or false
			conn.chat_blocked = data.player.chatBlocked or false
			MPAPI.connection_state.chat_enabled = conn.chat_enabled
			MPAPI.connection_state.chat_blocked = conn.chat_blocked
		end

		callback(nil, data)
	end)
end

MPAPI._internal.send_chat_message = function(code, message, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:send_chat_message(conn.jwt_token, code, message, callback)
end
