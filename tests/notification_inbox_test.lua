-- Contract test: the Notification queue and inbox. Waiting Notifications
-- show one at a time as "1 of N" to "N of N", none twice; a live one is a
-- chat line and is marked read; an unknown kind is left unread. Run from the
-- MPAPI repository root: luajit tests/notification_inbox_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local clock = 100
love = { timer = { getTime = function() return clock end } }
local deferred = nil
local chat, rpcs, handlers, loaded = {}, {}, {}, {}
local pending_reply = { notifications = {} }
MPAPI = {
	_internal = {},
	ConnectionState = { CONNECTED = 'connected', DISCONNECTED = 'disconnected' },
	load_mpapi_file = function(path)
		loaded[path] = loaded[path] or dofile(path)
		return loaded[path]
	end,
	sendDebugMessage = function() end,
	chat = {
		addMessage = function(text)
			chat[#chat + 1] = text
		end,
	},
	networking = {
		nakama_notify = {
			Code = { NOTIFICATION = 112 },
			on = function(code, fn)
				handlers[code] = fn
			end,
		},
		nakama_lobby = {
			rpc = function(id, body, cb)
				rpcs[#rpcs + 1] = { id = id, body = body }
				if id == 'notifications_pending' and deferred then
					deferred = function()
						cb(nil, pending_reply)
					end
				elseif id == 'notifications_pending' then
					cb(nil, pending_reply)
				else
					cb(nil, {})
				end
			end,
		},
	},
}

local Queue = MPAPI.load_mpapi_file('api/notification/queue.lua')
local Kinds = MPAPI.load_mpapi_file('api/notification/kinds.lua')
Kinds.register('test_kind', function(params)
	return 'Result ' .. tostring(params.n)
end)
dofile('api/notification/inbox.lua')
local inbox = MPAPI._internal.notification_inbox

-- Queue: three entries show as 1 of 3 to 3 of 3, in order, one at a time.
local q = Queue.new()
for i = 1, 3 do
	check(Queue.add(q, { id = 'n' .. i, text = 'text ' .. i }), 'entry ' .. i .. ' is added')
end
check(not Queue.add(q, { id = 'n2', text = 'again' }), 'an id already taken is not added twice')
for i = 1, 3 do
	local entry, position, total = Queue.next(q)
	check(entry.text == 'text ' .. i, 'entries come in order')
	check(position == i and total == 3, ('%d of 3 expected, got %s of %s'):format(i, position, total))
	Queue.close(q)
end
check(Queue.next(q) == nil, 'nothing is left after the third')
Queue.add(q, { id = 'n4', text = 'text 4' })
local _, position, total = Queue.next(q)
check(position == 1 and total == 1, 'a later batch counts from 1 of 1')
Queue.forget(q)
check(not Queue.has_pending(q) and not Queue.is_seen(q, 'n4'), 'forget clears the queue and the seen ids')

-- Inbox, offline then login: waiting ones queue; reading happens as each shows.
pending_reply = {
	notifications = {
		{ id = 'a', kind = 'test_kind', params = { n = 1 } },
		{ id = 'b', kind = 'test_kind', params = { n = 2 } },
		{ id = 'c', kind = 'test_kind', params = { n = 3 } },
		{ id = 'd', kind = 'future_kind', params = {} },
	},
}
inbox.on_state_change(MPAPI.ConnectionState.CONNECTED, { old_state = MPAPI.ConnectionState.DISCONNECTED })
check(#rpcs == 1 and rpcs[1].id == 'notifications_pending', 'login lists the waiting Notifications')
check(#inbox.queue.pending == 3, 'three known Notifications are queued, the unknown kind is skipped')
check(#rpcs == 1, 'nothing is marked read before it is shown')
local seen_texts = {}
for i = 1, 3 do
	local entry, pos, total = Queue.next(inbox.queue)
	entry.on_shown()
	Queue.close(inbox.queue)
	seen_texts[#seen_texts + 1] = ('%s (%d of %d)'):format(entry.text, pos, total)
end
check(seen_texts[1] == 'Result 1 (1 of 3)' and seen_texts[3] == 'Result 3 (3 of 3)', 'order and counts: ' .. table.concat(seen_texts, ', '))
check(#rpcs == 4 and rpcs[2].id == 'notifications_read' and rpcs[2].body.ids[1] == 'a', 'each is marked read as it shows')

-- A second login lists nothing already read; the server drops read ones, and
-- the seen ids guard a copy that would come twice in one session.
rpcs = {}
inbox.receive_waiting({ id = 'a', kind = 'test_kind', params = { n = 1 } })
check(not Queue.has_pending(inbox.queue), 'a Notification already taken this session is not queued again')

-- Live: a chat line, marked read, never queued; twice is one line.
inbox.receive_live({ id = 'e', kind = 'test_kind', params = { n = 5 } })
inbox.receive_live({ id = 'e', kind = 'test_kind', params = { n = 5 } })
check(#chat == 1 and chat[1] == 'Result 5', 'a live Notification is one chat line')
check(#rpcs == 1 and rpcs[1].id == 'notifications_read' and rpcs[1].body.ids[1] == 'e', 'a live Notification is marked read')
check(not Queue.has_pending(inbox.queue), 'a live Notification is not queued for the overlay')
inbox.receive_live({ id = 'f', kind = 'future_kind', params = {} })
check(#chat == 1 and #rpcs == 1, 'an unknown kind is neither printed nor marked read')
check(handlers[112] == inbox.receive_live, 'the live push is wired to code 112')

-- Login gate: the first overlay waits for every list, so N is final.
inbox.on_state_change(MPAPI.ConnectionState.DISCONNECTED, {})
pending_reply = { notifications = { { id = 'p1', kind = 'test_kind', params = { n = 1 } } } }
deferred = true
inbox.on_state_change(MPAPI.ConnectionState.CONNECTED, { old_state = MPAPI.ConnectionState.DISCONNECTED })
Queue.hold(inbox.queue, 'warnings', clock + inbox.login_wait)
Queue.hold(inbox.queue, 'avatars', clock + inbox.login_wait)
check(not Queue.ready(inbox.queue, clock), 'nothing shows while the lists are out')
Queue.release(inbox.queue, 'warnings')
inbox.receive_waiting({ id = 'w1', kind = 'test_kind', params = { n = 2 } })
check(not Queue.ready(inbox.queue, clock), 'one answered list does not open the gate')
deferred()
check(not Queue.ready(inbox.queue, clock), 'the stored list answered, the avatar list has not')
Queue.release(inbox.queue, 'avatars')
inbox.receive_waiting({ id = 'a1', kind = 'test_kind', params = { n = 3 } })
check(Queue.ready(inbox.queue, clock), 'every list answered: the first overlay may show')
local _, first, count = Queue.next(inbox.queue)
check(first == 1 and count == 3, 'the first overlay says 1 of 3')
Queue.close(inbox.queue)
Queue.forget(inbox.queue)
deferred = nil

-- A list that never answers (or fails) holds the queue only until the timeout.
Queue.hold(inbox.queue, 'avatars', clock + inbox.login_wait)
inbox.receive_waiting({ id = 't1', kind = 'test_kind', params = { n = 4 } })
check(not Queue.ready(inbox.queue, clock + inbox.login_wait - 1), 'held before the timeout')
check(Queue.ready(inbox.queue, clock + inbox.login_wait), 'shown after the timeout')
Queue.forget(inbox.queue)
check(Queue.ready(inbox.queue, clock) == false and not Queue.is_held(inbox.queue, clock), 'forget drops the holds')

-- Disconnect drops the unshown queue; the server still holds those.
inbox.receive_waiting({ id = 'g', kind = 'test_kind', params = { n = 7 } })
inbox.on_state_change(MPAPI.ConnectionState.DISCONNECTED, {})
check(not Queue.has_pending(inbox.queue), 'a disconnect forgets what was not shown')

print(('ok   %d checks'):format(checks))
