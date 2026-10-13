-- Moderation pushed over the Nakama socket (config nakama_only): bans and
-- the queue tickets they cost. The MQTT path has the API's EMQX kick and
-- matchmaking messages instead.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

local M = {}

local TITLES = {
	account = 'k_banned_title',
	queue = 'k_queue_banned_title',
	chat = 'k_chat_banned_title',
}

-- The server's "Account banned ..." login refusal (nakama/src/moderation/
-- access.ts ACCOUNT_BANNED), or nil for any other error.
function M.account_ban_message(err)
	if type(err) ~= 'string' then
		return nil
	end
	local at = err:find('Account banned', 1, true)
	return at and err:sub(at) or nil
end

-- "until <ISO time>" from epoch ms, or '' for a permanent ban.
local function until_text(expires_at)
	local ms = tonumber(expires_at)
	if not ms then
		return ''
	end
	return ' until ' .. os.date('!%Y-%m-%d %H:%M UTC', math.floor(ms / 1000))
end

function M.ban_body(ban)
	local kind = TITLES[ban.banType] and ban.banType or 'account'
	local text = localize('k_' .. kind .. '_banned_body') .. until_text(ban.expiresAt)
	if type(ban.reason) == 'string' and ban.reason ~= '' then
		text = text .. ': ' .. ban.reason
	end
	return text
end

local function on_banned(ban)
	local kind = TITLES[ban.banType] and ban.banType or 'account'
	MPAPI.sendWarnMessage('[moderation] ' .. kind .. ' ban: ' .. tostring(ban.reason))
	if kind == 'queue' and MPAPI.matchmaking and MPAPI.matchmaking.leave_all then
		MPAPI.matchmaking.leave_all()
	end
	if kind == 'account' and C.connection then
		-- The server drops the session too; going DISCONNECTED first keeps the
		-- socket from being reopened.
		C.connection.banned = ban
		C.connection:disconnect()
	end
	if MPAPI.show_banned_notice then
		MPAPI.show_banned_notice(TITLES[kind], M.ban_body(ban))
	end
end

-- A queue was cancelled for this player: handled like the API's
-- queue_cancelled, after giving up the ticket (on MQTT the API dequeued the
-- player itself). A failed ranked-readiness check names no queue and
-- cancels every ranked one. A refused matched group (requeue) needs nothing
-- here: its matched message carries no match, which queues again
-- (api/matchmaking/dispatch.lua on_nakama_matched).
local function on_queue_cancelled(msg)
	local mm = MPAPI._internal.mm
	if not mm or msg.requeue then
		return
	end
	local targets = {}
	if msg.modId then
		targets[1] = mm.find_handle_by_mode(msg.modId, msg.mode)
	else
		for _, h in ipairs(mm.handles) do
			if h._nakama_ranked then
				targets[#targets + 1] = h
			end
		end
	end
	for _, handle in ipairs(targets) do
		if handle._nakama_ticket then
			MPAPI.networking.nakama_lobby.unqueue(handle._nakama_ticket)
			handle._nakama_ticket = nil
		end
		mm.dispatch({
			type = MPAPI.MatchmakingMessage.QUEUE_CANCELLED,
			modId = handle.mod_id,
			gameMode = handle.game_mode,
			reason = msg.reason,
		})
	end
end

do
	local notify = MPAPI.networking.nakama_notify
	if notify then
		notify.on(notify.Code.BANNED, on_banned)
		notify.on(notify.Code.QUEUE_CANCELLED, on_queue_cancelled)
	end
end

MPAPI._internal.moderation = M
