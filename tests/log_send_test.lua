-- Contract test for how the lobby sends its log events (api/action/builtin.lua).
local T = dofile('tests/support.lua')
local check = T.check

-- Every log event is numbered, kept until an ack covers it, and sent again after a lost batch,
-- a refusal, a local refusal or a reconnect.
T.part(function()
	package.preload['json'] = function() return dofile('lib/nakama/util/json.lua') end
	love = { timer = { getTime = function() return 0 end } }
	local queued = {}
	G = { E_MANAGER = { add_event = function(_, event) queued[#queued + 1] = event end } }
	Event = function(spec) return spec end
	MPAPI = T.lobby_mpapi({
		ActionTypes = { mpapi_log_event = {}, mpapi_log_events = {} },
		networking = { nakama_lobby = { set_grace_seconds = function() end, leave = function() end } },
		set_player_ready = function() end,
	})
	dofile('api/lobby/state.lua')
	local L = MPAPI._internal.lobby
	dofile('api/action/builtin.lua')

	-- A lobby whose sends are recorded. `mode` decides what a send returns:
	-- true (sent), false (socket down), nil (refused locally).
	local function new_lobby()
		local lobby = L.create_object({})
		lobby._game = { started = { run_id = 'r1' } }
		lobby.sent = {}
		lobby.mode = true
		lobby.action = function()
			local instance = {}
			function instance:callback(fn)
				self._cb = fn
				return self
			end
			function instance:send(_, payload)
				if lobby.mode ~= true then
					return lobby.mode
				end
				lobby.sent[#lobby.sent + 1] = { payload = payload, cb = self._cb }
				return true
			end
			return instance
		end
		return lobby
	end

	local function seqs_of(entry)
		local payload = entry.payload
		local out = {}
		for _, e in ipairs(payload.events or { payload }) do
			out[#out + 1] = e.seq
		end
		return table.concat(out, ',')
	end

	local function record(lobby, count)
		for t = 1, count do
			L.send_log_event(lobby, 'play', t)
		end
		queued[#queued].func()
	end

	local function fire_resend_timer()
		for _, event in ipairs(queued) do
			if event.trigger == 'after' and not event.fired then
				event.fired = true
				event.func()
				return true
			end
		end
		return false
	end

	-- Events are numbered from 1 per run, and the batch that ends a flush asks for the ack.
	local lobby = new_lobby()
	record(lobby, 3)
	check(#lobby.sent == 1 and seqs_of(lobby.sent[1]) == '1,2,3', 'numbered 1,2,3, got ' .. seqs_of(lobby.sent[1]))
	check(lobby.sent[1].payload.ack == true, 'the batch asks for the ack')
	lobby.sent[1].cb({}, { ack = true, got = 3 })
	check(lobby._log_inflight == nil and lobby._log_acked == 3, 'an ack that covers the batch frees it')
	check(fire_resend_timer() == false or lobby._log_inflight == nil, 'nothing to send again')
	local before = #lobby.sent
	record(lobby, 1)
	check(seqs_of(lobby.sent[before + 1]) == '4', 'numbering goes on')

	-- A lost batch (no ack) is sent again by the timer once the server is known to count.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	lobby.sent[1].cb({}, { ack = true, got = 2 })
	queued = {}
	record(lobby, 2) -- seq 3,4: this batch is lost, no ack comes
	check(seqs_of(lobby.sent[2]) == '3,4', 'second batch is 3,4')
	check(fire_resend_timer(), 'a resend timer is armed')
	check(#lobby.sent == 3 and seqs_of(lobby.sent[3]) == '3,4', 'the lost batch goes out again, got ' .. #lobby.sent)
	lobby.sent[3].cb({}, { ack = true, got = 4 })
	check(lobby._log_inflight == nil, 'its ack frees it')

	-- A short ack (the server lacks earlier events) sends from the first one it lacks.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	lobby.sent[1].cb({}, { ack = true, got = 2 })
	record(lobby, 2) -- seq 3,4 lost
	record(lobby, 2) -- seq 5,6 arrive, the server holds only up to 2
	lobby.sent[3].cb({}, { ack = true, got = 2 })
	check(#lobby.sent == 3, 'no progress in the ack: wait for the timer')
	check(fire_resend_timer(), 'the timer is armed')
	check(seqs_of(lobby.sent[4]) == '3,4,5,6', 'the timer sends from the first event the server lacks, got ' .. seqs_of(lobby.sent[4]))
	lobby.sent[4].cb({}, { ack = true, got = 4 })
	check(seqs_of(lobby.sent[5]) == '5,6', 'progress in the ack sends the rest at once')

	-- A reconnect sends what was sent and not acked.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	lobby.sent[1].cb({}, { ack = true, got = 2 })
	record(lobby, 3) -- 3,4,5 sent on a dead socket
	L.resend_log_events(lobby)
	check(seqs_of(lobby.sent[#lobby.sent]) == '3,4,5', 'the reconnect sends them again, got ' .. seqs_of(lobby.sent[#lobby.sent]))

	-- A copy the server already holds is covered by the ack: nothing more goes out.
	local count = #lobby.sent
	lobby.sent[#lobby.sent].cb({}, { ack = true, got = 5 })
	lobby.sent[count - 0].cb({}, { ack = true, got = 5 })
	check(#lobby.sent == count and lobby._log_inflight == nil, 'a duplicate ack sends nothing')

	-- A batch the client could not send (socket down, or refused locally) is kept.
	for _, mode in ipairs({ false, nil }) do
		queued = {}
		lobby = new_lobby()
		lobby.mode = mode
		record(lobby, 2)
		check(#lobby.sent == 0 and #lobby._unsent_log_events == 2, 'kept when send returns ' .. tostring(mode))
		lobby.mode = true
		L.resend_log_events(lobby)
		check(#lobby.sent == 1 and seqs_of(lobby.sent[1]) == '1,2', 'sent once it can go')
	end

	-- A refused batch is kept and sent again by the timer.
	queued = {}
	lobby = new_lobby()
	record(lobby, 1)
	lobby.sent[1].cb({}, { ack = true, got = 1 })
	queued = {}
	record(lobby, 2)
	lobby.sent[2].cb({}, nil, { kind = 'ACTION_REJECTED', message = 'rate_limited' })
	check(lobby._log_inflight ~= nil, 'a refused batch stays kept')
	check(fire_resend_timer(), 'a resend timer is armed after a refusal')
	check(seqs_of(lobby.sent[3]) == '2,3', 'and goes out again, got ' .. tostring(lobby.sent[3] and seqs_of(lobby.sent[3])))

	-- A server that sends no count (an older one): the ack covers the batch, nothing is sent again.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	lobby.sent[1].cb({}, { ack = true })
	check(lobby._log_inflight == nil and lobby._log_counted == false, 'an ack with no count frees the batch')
	L.resend_log_events(lobby)
	check(#lobby.sent == 1, 'and a reconnect sends nothing again')

	-- An ack for an earlier run is ignored.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	local stale = lobby.sent[1]
	lobby._game.started = { run_id = 'r2' }
	record(lobby, 1)
	stale.cb({}, { ack = true, got = 0 })
	check(seqs_of(lobby.sent[2]) == '1' and lobby._log_inflight[1].run == 'r2', 'the new run starts again at 1')

	-- A new process rejoins the same run: the snapshot's count is where numbering goes on.
	queued = {}
	lobby = new_lobby()
	L.adopt_log_seq(lobby, 12)
	record(lobby, 2)
	check(seqs_of(lobby.sent[1]) == '13,14', 'a rejoined client numbers from N+1, got ' .. seqs_of(lobby.sent[1]))

	-- A snapshot of a count of 0 changes nothing, and one with no count (an older server) too.
	queued = {}
	lobby = new_lobby()
	L.adopt_log_seq(lobby, 0)
	L.adopt_log_seq(lobby, nil)
	record(lobby, 1)
	check(seqs_of(lobby.sent[1]) == '1', 'no held events: numbering starts at 1')

	-- The same lobby object after a dropped socket keeps its higher counter and sends what the server lacks.
	queued = {}
	lobby = new_lobby()
	record(lobby, 2)
	lobby.sent[1].cb({}, { ack = true, got = 2 })
	record(lobby, 3) -- 3,4,5 sent on a dead socket
	L.adopt_log_seq(lobby, 2) -- the server holds 2
	L.resend_log_events(lobby)
	check(seqs_of(lobby.sent[#lobby.sent]) == '3,4,5', 'the same lobby sends 3,4,5 again, got ' .. seqs_of(lobby.sent[#lobby.sent]))
	record(lobby, 1)
	check(seqs_of(lobby.sent[#lobby.sent]) == '6', 'and goes on at 6')
	-- When the server holds more than the lobby sent (events whose ack was lost), they are not sent again.
	L.adopt_log_seq(lobby, 5)
	check(lobby._log_inflight == nil or lobby._log_inflight[1].seq == 6, 'events up to 5 are forgotten')
end)

-- lobby:leave sends the log events recorded this frame, the last batch asking for an ack, and
-- tells the server it leaves once the ack (or a refusal) comes back, or after a timeout,
-- whichever is first.
T.part(function()
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
	MPAPI = T.lobby_mpapi({
		ActionTypes = { mpapi_log_event = {}, mpapi_log_events = {} },
		networking = {
			nakama_lobby = {
				set_grace_seconds = function() end,
				leave = function() order[#order + 1] = 'leave' end,
			},
		},
		set_player_ready = function() end,
	})
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
	check(order[1] == 'event:END' and lobby.sent[1].payload.ack == true, 'the last batch of a flush asks for the ack that tells how far the server holds')

	-- A leave during a run ends the log with "left" before the last batch goes out.
	reset()
	lobby = new_lobby()
	local ended = {}
	MPAPI.replay = {
		_run_active = true,
		end_run = function(outcome)
			ended[#ended + 1] = outcome.result
			MPAPI.replay._run_active = false
			L.send_log_event(lobby, 'END', 1)
			L.send_log_event(lobby, 'CHK', 2)
		end,
	}
	lobby:leave()
	check(#ended == 1 and ended[1] == 'left', 'a leave during a run ends the log with left')
	check(order[1] == 'batch:2', 'the end and check events go out in the last batch, got ' .. tostring(order[1]))
	check(lobby.sent[1].payload.ack == true, 'that batch asks for an ack')
	lobby:leave()
	check(#ended == 1, 'a second leave ends nothing')

	-- A mod that already closed the log (a forfeit, a result) is not closed twice.
	reset()
	lobby = new_lobby()
	ended = {}
	MPAPI.replay._run_active = false
	lobby:leave()
	check(#ended == 0, 'a leave outside a run ends no log')
	check(order[1] == 'leave', 'and the leave goes at once')
	MPAPI.replay = nil
end)

T.done('log_send_test')
