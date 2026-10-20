-- Account/profile operations that round-trip to the server: discord linking,
-- display-name preference, preferred joker, mods, mutes and chat enablement.
-- The account lives on Nakama (BalatroMultiplayerServer nakama/src/player).
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

local function require_connected(callback)
	local conn = C.connection
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return nil
	end
	if not conn.session_token then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NO_TOKEN, 'No session token'), nil)
		return nil
	end
	return conn
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

-- The link finishes in the browser; Nakama then pushes ACCOUNT_UPDATED.
MPAPI._internal.get_discord_link_url = function(callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'discord_link_start', {}, callback)
	end
end

MPAPI._internal.set_use_discord_name = function(value, callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'profile_set_display', { useDiscordName = value }, callback, apply_account(conn))
	end
end

MPAPI._internal.set_preferred_joker = function(value, callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'profile_set_joker', { preferredJoker = value }, callback, apply_account(conn))
	end
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

-- Sent once per login, right after the socket opens (networking/connection.lua's
-- _nakama_connect): mods are launch-scoped, not lobby-scoped, so there's no
-- need to resend on join. The reply carries the account's standing
-- (api/connection/standing.lua), which gates matchmaking. cb(err, view) when
-- given; view is nil from a server without standings. A failure leaves the
-- standing unknown and that player's Mods tab empty for lobby peers.
MPAPI._internal.send_installed_mods = function(cb)
	cb = cb or function() end
	local conn = require_connected(cb)
	if not conn then
		return
	end
	nakama_rpc(conn, 'profile_set_mods', { mods = MPAPI.collect_installed_mods() }, function(err, data)
		if err then
			MPAPI.sendWarnMessage('[mods] Failed to send installed mods list: ' .. tostring(err.message or err))
			cb(err, nil)
			return
		end
		cb(nil, C.remember_standing(data and data.standing))
	end)
end

-- On success, conn.mute_list/MPAPI.connection_state.mute_list take the
-- server's returned mutedPlayerIds, rather than re-fetching.
local function nakama_mute(conn, target_id, muted, callback)
	nakama_rpc(conn, 'mute_set', { userId = target_id, muted = muted }, callback, function(data)
		conn.mute_list = {}
		for _, id in ipairs(data.mutedPlayerIds or {}) do
			conn.mute_list[id] = true
		end
		MPAPI.connection_state.mute_list = conn.mute_list
	end)
end

MPAPI._internal.mute_player = function(target_id, callback)
	local conn = require_connected(callback)
	if conn then
		nakama_mute(conn, target_id, true, callback)
	end
end

MPAPI._internal.unmute_player = function(target_id, callback)
	local conn = require_connected(callback)
	if conn then
		nakama_mute(conn, target_id, false, callback)
	end
end

-- Reports go through Nakama (moderation/report.ts), which adds the lobby's
-- evidence and hands them to the API. `code` is kept for older callers.
MPAPI._internal.report_player = function(code, target_id, report_type, message, callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'report_submit', {
			reportedUserId = target_id,
			type = report_type,
			message = message,
		}, callback)
	end
end

-- The kicker's own roster update arrives with the player_kicked broadcast,
-- like any other lobby event.
MPAPI._internal.kick_player = function(code, target_id, callback)
	local lobby = MPAPI.get_current_lobby()
	if not (lobby and lobby._nakama and lobby.code == code) then
		callback(MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'Not in that lobby'), nil)
		return
	end
	local NL = MPAPI.networking.nakama_lobby
	if NL.send(NL.ClientOp.KICK, { playerId = target_id }) then
		callback(nil, {})
	else
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected to the lobby'), nil)
	end
end

MPAPI._internal.unlink_discord = function(callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'discord_unlink', {}, callback, apply_account(conn))
	end
end

MPAPI._internal.enable_chat = function(callback)
	local conn = require_connected(callback)
	if conn then
		nakama_rpc(conn, 'chat_enable', {}, callback, apply_account(conn))
	end
end

-- Another session (or the server) changed the account.
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
