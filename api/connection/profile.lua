-- Account/profile operations that round-trip to the server: discord linking,
-- display-name preference, preferred joker, mods, mutes and chat enablement.
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

-- Under nakama_only the account lives on Nakama (BalatroMultiplayerServer
-- nakama/src/player): each call below goes to its RPC instead of the API.
local function nakama_only()
	return MPAPI.networking.nakama_only()
end

-- conn's Nakama RPC; apply(data) runs before callback(nil, data).
local function nakama_rpc(conn, id, body, callback, apply)
	conn:_nakama_rpc(id, body, function(err, data)
		if err then
			callback(MPAPI.make_error(MPAPI.ErrorKind.SERVER, err), nil)
			return
		end
		if apply then
			apply(data)
		end
		callback(nil, data)
	end)
end

local function apply_account(conn)
	return function(data)
		conn:_on_account_updated(data)
	end
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
	if nakama_only() then
		nakama_rpc(conn, 'profile_set_display', { useDiscordName = value }, callback, apply_account(conn))
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
	if nakama_only() then
		nakama_rpc(conn, 'profile_set_joker', { preferredJoker = value }, callback, apply_account(conn))
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
	if nakama_only() then
		nakama_rpc(conn, 'profile_set_mods', { mods = MPAPI.collect_installed_mods() }, function(err)
			if err then
				MPAPI.sendWarnMessage('[mods] Failed to send installed mods list: ' .. tostring(err.message or err))
			end
		end)
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
-- A Nakama lobby's roster ids are Nakama user ids, which the API's mute
-- endpoints don't know: there a mute lasts for the session, kept locally --
-- unless the account itself is on Nakama (nakama_only), which keeps it.
local function set_local_mute(conn, target_id, muted, callback)
	conn.mute_list = conn.mute_list or {}
	conn.mute_list[target_id] = muted or nil
	MPAPI.connection_state.mute_list = conn.mute_list
	callback(nil, { mutedPlayerIds = conn.mute_list })
end

local function nakama_mute(conn, target_id, muted, callback)
	nakama_rpc(conn, 'mute_set', { userId = target_id, muted = muted }, callback, function(data)
		conn.mute_list = {}
		for _, id in ipairs(data.mutedPlayerIds or {}) do
			conn.mute_list[id] = true
		end
		MPAPI.connection_state.mute_list = conn.mute_list
	end)
end

local function in_nakama_lobby()
	local lobby = MPAPI.get_current_lobby()
	return lobby ~= nil and lobby._nakama == true
end

MPAPI._internal.mute_player = function(target_id, callback)
	local conn = require_connected(callback)
	if not conn then
		return
	end
	if nakama_only() then
		nakama_mute(conn, target_id, true, callback)
		return
	end
	if in_nakama_lobby() then
		set_local_mute(conn, target_id, true, callback)
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
	if nakama_only() then
		nakama_mute(conn, target_id, false, callback)
		return
	end
	if in_nakama_lobby() then
		set_local_mute(conn, target_id, false, callback)
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

	-- A Nakama lobby's reports go through Nakama (moderation/report.ts), which
	-- adds the lobby's evidence and hands them to the API.
	if nakama_only() or in_nakama_lobby() then
		nakama_rpc(conn, 'report_submit', {
			reportedUserId = target_id,
			type = report_type,
			message = message,
		}, callback)
		return
	end

	conn.api:report_player(conn.jwt_token, code, target_id, report_type, message, callback)
end

-- No optimistic local-state mutation needed here either -- the kicker's own
-- roster update happens naturally when its own client receives the
-- player_kicked broadcast back over lobby/{code}/events, same as any other
-- lobby event.
MPAPI._internal.kick_player = function(code, target_id, callback)
	local lobby = MPAPI.get_current_lobby()
	if lobby and lobby._nakama and lobby.code == code then
		local NL = MPAPI.networking.nakama_lobby
		if NL.send(NL.ClientOp.KICK, { playerId = target_id }) then
			callback(nil, {})
		else
			callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected to the lobby'), nil)
		end
		return
	end

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
	if nakama_only() then
		nakama_rpc(conn, 'chat_enable', {}, callback, apply_account(conn))
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
		-- Nakama lobbies' chat checks Nakama's own copy of the consent.
		conn:_mirror_consent_to_nakama(data.player)

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

-- Another session (or the server) changed the account: Nakama's counterpart
-- of the MQTT account/* topics.
do
	local notify = MPAPI.networking.nakama_notify
	if notify then
		notify.on(notify.Code.ACCOUNT_UPDATED, function(content)
			if C.connection then
				C.connection:_on_account_updated(content)
			end
		end)
	end
end
