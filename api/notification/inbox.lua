-- Receives Notifications from the server (code 112, stored on the server
-- until read). Online, one arrives as a push: it is printed as a chat line, in
-- the menu too, and marked read. A Notification that waited while the player
-- was offline is listed at login and queued for the overlay
-- (ui/notification_overlay.lua), which marks each read as it shows it. The
-- overlay waits until every login list has answered, so its count is final.
local notify = MPAPI.networking.nakama_notify
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn
local Queue = MPAPI.load_mpapi_file('api/notification/queue.lua')
local Kinds = MPAPI.load_mpapi_file('api/notification/kinds.lua')

local COLOUR_SYSTEM = { 1, 1, 0 }

local queue = Queue.new()

local function mark_read(id)
	if id == nil then
		return
	end
	MPAPI.networking.nakama_lobby.rpc('notifications_read', { ids = { id } }, function(err)
		if err then
			MPAPI.sendDebugMessage('[notification] could not mark ' .. tostring(id) .. ' read: ' .. tostring(err))
		end
	end)
end

-- A push while online: a chat line, then read.
local function receive_live(content)
	if type(content) ~= 'table' or Queue.is_seen(queue, content.id) then
		return
	end
	local text = Kinds.describe(content.kind, content.params)
	if not text then
		return
	end
	Queue.mark_seen(queue, content.id)
	MPAPI.chat.addMessage(text, COLOUR_SYSTEM)
	mark_read(content.id)
end

-- One listed at login: queued for the overlay.
local function receive_waiting(notification)
	if type(notification) ~= 'table' or Queue.is_seen(queue, notification.id) then
		return
	end
	local text = Kinds.describe(notification.kind, notification.params)
	if not text then
		return
	end
	local id = notification.id
	Queue.add(queue, {
		id = id,
		text = text,
		on_shown = function()
			mark_read(id)
		end,
	})
end

-- How long the login lists may hold the first overlay, in seconds.
local LOGIN_WAIT = 5

local function now()
	return love.timer.getTime()
end

local function fetch_waiting()
	Queue.hold(queue, 'notifications', now() + LOGIN_WAIT)
	MPAPI.networking.nakama_lobby.rpc('notifications_pending', {}, function(err, data)
		Queue.release(queue, 'notifications')
		if err then
			MPAPI.sendDebugMessage('[notification] could not list waiting: ' .. tostring(err))
			return
		end
		for _, notification in ipairs(data.notifications or {}) do
			receive_waiting(notification)
		end
	end)
end

if notify then
	notify.on(notify.Code.NOTIFICATION, receive_live)
end

local function on_state_change(new_state, context)
	local old_state = context and context.old_state
	if new_state == MPAPI.ConnectionState.CONNECTED and old_state ~= nil and old_state ~= new_state then
		fetch_waiting()
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED then
		Queue.forget(queue)
	end
end
C.state_change_callbacks = C.state_change_callbacks or {}
table.insert(C.state_change_callbacks, on_state_change)

MPAPI._internal.notification_inbox = {
	queue = queue,
	receive_live = receive_live,
	receive_waiting = receive_waiting,
	login_wait = LOGIN_WAIT,
	now = now,
	on_state_change = on_state_change,
}
