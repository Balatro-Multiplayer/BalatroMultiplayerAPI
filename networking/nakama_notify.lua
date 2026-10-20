-- Server pushes over the Nakama socket. The server sends them as Nakama
-- notifications with a BMP code (BalatroMultiplayerServer nakama/src/notify.ts;
-- keep both lists in step). Handlers are registered by code and get the
-- decoded content table.
local N = {}

N.Code = {
	CHALLENGE = 100,
	ACCOUNT_UPDATED = 101,
	BANNED = 102,
	QUEUE_CANCELLED = 103,
	-- 104 and 106 are retired (never sent); don't reuse them.
	INTEGRITY = 105,
	-- Persistent: also waits in the notification list for the next login.
	AVATAR_UNLOCKED = 107,
	-- The account's queue standing changed (allowlist or enforcement edit).
	STANDING_CHANGED = 108,
}

local handlers = {} -- code -> { fn, ... }

-- fn(content, notification). Returns nothing; handlers stay for the session.
function N.on(code, fn)
	handlers[code] = handlers[code] or {}
	table.insert(handlers[code], fn)
end

local function decode(content)
	if type(content) == 'table' then
		return content
	end
	local ok, data = pcall(MPAPI.json_decode, content or '{}')
	return ok and type(data) == 'table' and data or {}
end

function N.dispatch_one(notification)
	local code = tonumber(notification.code)
	local list = code and handlers[code]
	if not list then
		MPAPI.sendDebugMessage('[nakama_notify] no handler for code ' .. tostring(notification.code))
		return
	end
	local content = decode(notification.content)
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, content, notification)
		if not ok then
			MPAPI.sendWarnMessage('[nakama_notify] handler for ' .. tostring(code) .. ' failed: ' .. tostring(err))
		end
	end
end

-- The socket's on_notifications message: { notifications = { notifications = {...} } }.
function N.dispatch(message)
	local wrapper = message and message.notifications
	local list = wrapper and (wrapper.notifications or wrapper) or {}
	for _, notification in ipairs(list) do
		N.dispatch_one(notification)
	end
end

-- Persistent notifications are not re-pushed when the socket connects: they
-- wait in the account's notification list. cb(list) gets the stored ones with
-- `code` (decoded content in .content_table), {} when the client can't list.
local LIST_PAGE = 100
function N.list_persistent(client, code, cb)
	if not (client and client.list_notifications) then
		cb({})
		return
	end
	client.list_notifications(LIST_PAGE, nil, function(result)
		local found = {}
		for _, notification in ipairs((result and not result.error and result.notifications) or {}) do
			if tonumber(notification.code) == code then
				notification.content_table = decode(notification.content)
				found[#found + 1] = notification
			end
		end
		cb(found)
	end)
end

-- Removes stored notifications once they have been dealt with. Fire and forget.
function N.delete_persistent(client, ids)
	if not (client and client.delete_notifications) or not ids or #ids == 0 then
		return
	end
	client.delete_notifications(ids, function(result)
		if result and result.error then
			MPAPI.sendDebugMessage('[nakama_notify] delete failed: ' .. tostring(result.error.message or result.error))
		end
	end)
end

MPAPI.networking.nakama_notify = N
