-- Contract test: lobby:leave sends the log events recorded this frame, the last
-- batch asking for an ack, and tells the server it leaves once the ack (or a
-- refusal) comes back, or after a timeout, whichever is first. Run from the MPAPI repository root:
-- luajit tests/leave_flush_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

package.preload['json'] = function() return dofile('lib/nakama/util/json.lua') end
love = { timer = { getTime = function() return 0 end } }
local order = {}
local queued = {}
local function timeout_event()
	for _, event in ipairs(queued) do
		if event.trigger == 'after' and not event.fired then
			return event
		end
	end
end
G = { E_MANAGER = { add_event = function(_, event) queued[#queued + 1] = event end } }
Event = function(spec) return spec end
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, {
		__call = function() end,
	}),
	ActionTypes = { mpapi_log_event = {}, mpapi_log_events = {} },
	get_current_lobby = function() end,
	LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
	networking = {
		nakama_lobby = {
			set_grace_seconds = function() end,
			leave = function() order[#order + 1] = 'leave' end,
		},
	},
	set_player_ready = function() end,
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/lobby/state.lua')
local L = MPAPI._internal.lobby
dofile('api/action/builtin.lua')


-- A lobby whose sends are recorded; the server's answers are driven by the test.
local function new_lobby()
	local lobby = L.create_object({})
	lobby._game = { started = { run_id = 'r1' } }
	lobby.sent = {}
	lobby.action = function()
		local instance = {}
		function instance:callback(fn)
			self._cb = fn
			return self
		end
		function instance:send(_, payload)
			local entry = { payload = payload, cb = self._cb }
			lobby.sent[#lobby.sent + 1] = entry
			order[#order + 1] = payload.events and ('batch:' .. #payload.events) or ('event:' .. payload.t)
			return true
		end
		return instance
	end
	return lobby
end
local function reset()
	order = {}
	queued = {}
end
local function fire_timeout()
	local event = timeout_event()
	check(event ~= nil, 'a timeout is scheduled')
	event.fired = true
	event.func()
end

-- The last batch asks for an ack; the leave waits for the reply.
local lobby = new_lobby()
L.send_log_event(lobby, 'END', 1)
L.send_log_event(lobby, 'CHK', 2)
check(#order == 0, 'events wait for the end of the frame')
lobby:leave()
check(order[1] == 'batch:2', 'the events go out first, got ' .. tostring(order[1]))
check(lobby.sent[1].payload.ack == true, 'the last batch asks for an ack')
check(#order == 1, 'the leave waits for the ack, got ' .. table.concat(order, ','))
check(lobby._unsent_log_events == nil, 'nothing stays kept')
lobby.sent[1].cb(nil, { ack = true })
check(order[2] == 'leave', 'the ack lets the leave go')
lobby.sent[1].cb(nil, { ack = true })
fire_timeout()
check(#order == 2, 'a late ack or timeout leaves nothing more')
lobby:leave()
check(#order == 2, 'a second leave does nothing')
check(timeout_event() == nil, 'the timeout was the only one, now fired')

-- A refusal also lets the leave go.
reset()
lobby = new_lobby()
L.send_log_event(lobby, 'END', 1)
lobby:leave()
check(lobby.sent[1].payload.ack == true and lobby.sent[1].payload.t == 'END', 'a single event asks for an ack too')
lobby.sent[1].cb(nil, nil, { kind = 'ACTION_REJECTED' })
check(order[#order] == 'leave', 'a refusal lets the leave go')

-- No reply: the timeout lets the leave go, once.
reset()
lobby = new_lobby()
L.send_log_event(lobby, 'END', 1)
L.send_log_event(lobby, 'CHK', 2)
lobby:leave()
check(#order == 1, 'still waiting')
fire_timeout()
check(order[2] == 'leave', 'the timeout lets the leave go')
lobby.sent[1].cb(nil, { ack = true })
check(#order == 2, 'an ack after the timeout leaves nothing more')

-- Only the last of several batches asks for an ack.
reset()
lobby = new_lobby()
for t = 1, L.LOG_BATCH_MAX + 1 do
	L.send_log_event(lobby, 'play', t)
end
lobby:leave()
check(#lobby.sent == 2, 'two batches, got ' .. #lobby.sent)
check(lobby.sent[1].payload.ack == nil, 'an earlier batch asks for no ack')
check(lobby.sent[2].payload.ack == true, 'the last batch asks for an ack')
check(#order == 2, 'the leave waits')
lobby.sent[2].cb(nil, { ack = true })
check(order[3] == 'leave', 'the last ack lets the leave go')

-- Nothing to send: leave at once.
reset()
lobby = new_lobby()
lobby:leave()
check(order[1] == 'leave' and #lobby.sent == 0, 'no events: the leave goes at once')
check(timeout_event() == nil, 'no timeout is scheduled')

-- A lobby torn down while waiting does not leave again.
reset()
lobby = new_lobby()
L.send_log_event(lobby, 'END', 1)
lobby:leave()
lobby._destroyed = true
fire_timeout()
check(#order == 1, 'a destroyed lobby does not call the server leave')

-- The end-of-frame flush finds nothing after a leave flushed everything.
reset()
lobby = new_lobby()
L.send_log_event(lobby, 'END', 1)
queued[1].func()
check(order[1] == 'event:END' and lobby.sent[1].payload.ack == nil, 'the normal flush asks for no ack')

print(('ok   %d checks'):format(checks))
