-- Moderation pushed over the Nakama socket: bans and the queue tickets they
-- cost.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

local M = {}

local TITLES = {
	account = 'k_banned_title',
	queue = 'k_queue_banned_title',
	chat = 'k_chat_banned_title',
}

-- The login refusals that are bans, by the text they start with: a wire
-- contract with nakama/src/moderation/access.ts (ACCOUNT_BANNED,
-- NETWORK_BANNED). A reworded server message stops showing as a ban.
local LOGIN_BANS = {
	{ prefix = 'Account banned', title_key = 'k_banned_title' },
	{ prefix = 'Your network is banned', title_key = 'k_network_banned_title' },
}

-- A login refusal that is a ban, as { title_key, message } with the server's
-- text from the ban on (the SDK may put a runtime prefix before it), or nil
-- for any other error. Pure.
function M.login_ban(err)
	if type(err) ~= 'string' then
		return nil
	end
	for _, ban in ipairs(LOGIN_BANS) do
		local at = err:find(ban.prefix, 1, true)
		if at then
			return { title_key = ban.title_key, message = err:sub(at) }
		end
	end
	return nil
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
		-- The server removes us from our lobby too, but that kick comes after
		-- this push over the socket we are about to close, so it never
		-- arrives: leave the lobby view here.
		local lobby = MPAPI._internal.lobby and MPAPI._internal.lobby.current
		if lobby then
			MPAPI._internal.lobby.drop(lobby)
		end
		-- The server drops the session too; going DISCONNECTED first keeps the
		-- socket from being reopened.
		C.connection.banned = ban
		C.connection:disconnect()
	end
	if MPAPI.show_banned_notice then
		MPAPI.show_banned_notice(TITLES[kind], M.ban_body(ban))
	end
end

-- The standing refusal a QUEUE_CANCELLED carries ({code, mods}), or nil
-- when it was cancelled for another reason. Pure.
local function standing_refusal_of(msg)
	for _, code in pairs(MPAPI.QueueRefusalCode) do
		if msg.code == code then
			local mods = {}
			for _, key in ipairs(type(msg.mods) == 'table' and msg.mods or {}) do
				mods[#mods + 1] = tostring(key)
			end
			return { code = code, mods = mods }
		end
	end
	return nil
end
M.standing_refusal_of = standing_refusal_of

-- The handles a QUEUE_CANCELLED ends: the named queue, or, for a failed
-- ranked-readiness check (which names none), every ranked one.
local function cancelled_handles(mm, msg)
	if msg.modId then
		return { mm.find_handle_by_mode(msg.modId, msg.mode) }
	end
	local targets = {}
	for _, h in ipairs(mm.handles) do
		if h._nakama_ranked then
			targets[#targets + 1] = h
		end
	end
	return targets
end

-- A queue was cancelled for this player: give up the ticket and end the
-- handle. The server can't remove the ticket itself, so the client drops it.
-- A refused matched group (requeue) needs nothing here: its matched message
-- carries no match, which queues again (api/matchmaking/dispatch.lua
-- on_nakama_matched).
local function on_queue_cancelled(msg)
	local mm = MPAPI._internal.mm
	if not mm or msg.requeue then
		return
	end
	local standing = standing_refusal_of(msg)
	local ended = false
	for _, handle in ipairs(cancelled_handles(mm, msg)) do
		if handle._nakama_ticket then
			MPAPI.networking.nakama_lobby.unqueue(handle._nakama_ticket)
			handle._nakama_ticket = nil
		end
		if standing then
			mm.refuse_handle(handle, standing)
		elseif msg.code then
			mm.end_handle(handle, MPAPI.make_error(MPAPI.ErrorKind.SERVER, tostring(msg.reason)))
		else
			mm.cancel_handle(handle, msg.reason)
		end
		ended = true
	end
	-- One notice for however many handles the cancel ended.
	if not ended then
		return
	end
	if standing then
		MPAPI.show_standing_refusal(standing)
	elseif msg.code and MPAPI.show_notice then
		MPAPI.show_notice('k_queue_failed_title', tostring(msg.reason))
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
