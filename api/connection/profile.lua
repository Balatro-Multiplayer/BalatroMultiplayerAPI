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

-- Enumerates every enabled, non-base-game SMODS mod as "ModId-version" strings
-- (direct port of the legacy hash-handshake's enumeration, minus the hash --
-- see BalatroMultiplayerPvP/lib/matchmaking.lua's now-superseded version).
-- Powers MPAPI's Lobby Info overlay's Mods tab for lobby peers.
function MPAPI.collect_installed_mods()
	local list = {}
	for key, mod in pairs(SMODS.Mods or {}) do
		if not mod.disabled and key ~= 'Balatro' then
			list[#list + 1] = key .. '-' .. tostring(mod.version or 'UNK')
		end
	end
	return list
end

-- Sent once, fire-and-forget, right after a fresh CONNECTED transition (see
-- api/connection/lifecycle.lua's connection_on_state_change) -- mods are
-- launch-scoped, not lobby-scoped, so there's no need to resend on join.
-- Failure just leaves that player's Mods tab empty for lobby peers; not fatal.
MPAPI._internal.send_installed_mods = function()
	local conn = require_connected(function() end)
	if not conn then
		return
	end

	conn.api:set_installed_mods(conn.jwt_token, MPAPI.collect_installed_mods(), function(err)
		if err then
			MPAPI.sendWarnMessage('[mods] Failed to send installed mods list: ' .. tostring(err))
		end
	end)
end

-- Optimistic local update (matches set_preferred_joker/enable_chat's pattern):
-- on success, apply the change to conn.mute_list/MPAPI.connection_state.mute_list
-- directly from the server's returned mutedPlayerIds, rather than re-fetching.
MPAPI._internal.mute_player = function(target_id, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:mute_player(conn.jwt_token, target_id, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		conn.mute_list = conn.mute_list or {}
		conn.mute_list[target_id] = true
		MPAPI.connection_state.mute_list = conn.mute_list

		callback(nil, data)
	end)
end

MPAPI._internal.unmute_player = function(target_id, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:unmute_player(conn.jwt_token, target_id, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		conn.mute_list = conn.mute_list or {}
		conn.mute_list[target_id] = nil
		MPAPI.connection_state.mute_list = conn.mute_list

		callback(nil, data)
	end)
end

-- No optimistic local-state mutation needed here (unlike mute) -- a report has
-- no persistent client-visible cache to keep in sync.
MPAPI._internal.report_player = function(code, target_id, report_type, message, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:report_player(conn.jwt_token, code, target_id, report_type, message, callback)
end

-- No optimistic local-state mutation needed here either -- the kicker's own
-- roster update happens naturally when its own client receives the
-- player_kicked broadcast back over lobby/{code}/events, same as any other
-- lobby event.
MPAPI._internal.kick_player = function(code, target_id, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end

	conn.api:kick_player(conn.jwt_token, code, target_id, callback)
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
