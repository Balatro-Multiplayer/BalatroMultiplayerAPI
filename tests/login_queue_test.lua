-- Contract test: a waiting warning and a waiting avatar unlock join the same
-- login queue as other Notifications ("1 of 4" to "4 of 4", one at a time),
-- are deleted from the stored list as each shows, and are not queued twice.
-- A warning or unlock that arrives while online is not queued. Run from the
-- MPAPI repository root: luajit tests/login_queue_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local deleted, listed = {}, {}
local handlers, loaded = {}, {}
G = { FUNCS = {}, UIT = {}, C = {}, STAGES = { MAIN_MENU = 1 }, STAGE = 0 }
localize = function(key)
	if type(key) == 'table' then
		return key.key
	end
	return key
end
MPAPI = {
	_internal = { conn = {} },
	ConnectionState = { CONNECTED = 'connected', DISCONNECTED = 'disconnected' },
	load_mpapi_file = function(path)
		loaded[path] = loaded[path] or dofile(path)
		return loaded[path]
	end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
	ui_element = function()
		return { as_overlay = function() end }
	end,
	update = function() end,
	networking = {
		nakama_notify = {
			Code = { WARNED = 109, AVATAR_UNLOCKED = 107 },
			on = function(code, fn)
				handlers[code] = fn
			end,
			list_persistent = function(_, code, cb)
				cb(listed[code] or {})
			end,
			delete_persistent = function(_, ids)
				for _, id in ipairs(ids) do
					deleted[#deleted + 1] = id
				end
			end,
		},
	},
}

local Queue = MPAPI.load_mpapi_file('api/notification/queue.lua')
local queue = Queue.new()
MPAPI._internal.notification_inbox = { queue = queue }
dofile('ui/warned_notice_overlay.lua')
dofile('ui/avatar_unlocked_toast.lua')
local warned = MPAPI._internal.warned_notice
local toast = MPAPI._internal.avatar_unlocked_toast

-- Two other Notifications already waiting, then the warning and the unlock.
Queue.add(queue, { id = 'a', text = 'first' })
Queue.add(queue, { id = 'b', text = 'second' })
warned.enqueue_waiting({ message = 'Be kind.', warnedAt = 0 }, 'w1')
toast.enqueue_waiting({ avatarIds = { 'j_baron' } }, 'v1')
warned.enqueue_waiting({ message = 'Be kind.', warnedAt = 0 }, 'w1')
toast.enqueue_waiting({ avatarIds = { 'j_baron' } }, 'v1')

local texts = {}
for i = 1, 4 do
	local entry, position, total = Queue.next(queue)
	check(entry ~= nil, 'entry ' .. i .. ' exists')
	check(position == i and total == 4, 'entry ' .. i .. ' is ' .. i .. ' of 4')
	if entry.on_shown then
		entry.on_shown()
	end
	texts[i] = entry.text
	Queue.close(queue)
end
check(Queue.next(queue) == nil, 'there is no fifth entry')
check(texts[3]:find('Be kind.', 1, true), 'the warning shows its message')
check(texts[4]:find('j_baron', 1, true), 'the unlock shows the avatar')
check(#deleted == 2 and deleted[1] == 'w1' and deleted[2] == 'v1', 'each stored copy is deleted as it shows')

-- A warning without a message is deleted and not queued.
deleted = {}
warned.enqueue_waiting({}, 'w2')
check(not Queue.has_pending(queue) and deleted[1] == 'w2', 'an empty warning is deleted, not queued')

-- Online: keeps its own pop up, nothing joins the login queue.
handlers[109]({ message = 'Live warning' }, { persistent = true, id = 'w3' })
handlers[107]({ avatarIds = { 'j_joker' } }, { persistent = true, id = 'v3' })
check(not Queue.has_pending(queue), 'a live warning and unlock are not queued')
check(#warned.queued() == 1 and #toast.queued() == 1, 'a live warning and unlock keep their own pop ups')

print('login_queue_test: ' .. checks .. ' checks passed')
