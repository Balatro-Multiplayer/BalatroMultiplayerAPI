-- Request/answer client layer on the lobby's Nakama match: MPAPI.request,
-- MPAPI.on_state and MPAPI.get_state.
--
-- A request gets exactly one result. It stays pending across a socket drop and,
-- once the rejoin snapshot is in, is sent again in issue order under its
-- original reqId (the server answers a repeat from its stored answer). The
-- shared match state is mirrored locally and checked by revision.
-- Decisions live in request_core.lua; this file holds the pending list, the
-- clock and the sends. Wire constants: protocol.lua.
local Protocol = MPAPI.load_mpapi_file('api/net/protocol.lua')
local Core = MPAPI.load_mpapi_file('api/net/request_core.lua')

local Shell = {}

-- Most seconds one frame adds to the connected-time clock.
local MAX_FRAME_DT = 0.5

-- deps = {
--   clock() -> seconds,
--   encode(value) -> json,
--   warn(message),
--   transport = {
--     in_match() -> bool   a lobby match is held, even while its socket is down and being rejoined
--     live() -> bool       the socket is up and the seat is rejoined
--     send(op, json) -> bool
--   },
-- }
function Shell.new(deps)
	local transport = deps.transport
	local self = {}

	local connection_id = nil
	local counter = 0
	local rev = nil -- nil until the first snapshot
	local match_state = {}
	-- Set from a snapshot of this connection; sends wait for it.
	local synced = false
	local unsupported = false
	local waiting = nil -- the internal snapshot request, while one is out
	local pending = {} -- entries in issue order
	local by_id = {}
	local deferred = {} -- { entry, ok, result } resolved on the next update
	local subscribers = {} -- key -> array of { fn, active }

	-- Time spent connected: the deadline counts this, so a long drop times nothing out.
	local connected_time = 0
	local last_clock = deps.clock()

	local function copy(list)
		local out = {}
		for i, v in ipairs(list) do
			out[i] = v
		end
		return out
	end

	local function call(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then
			deps.warn('[net] callback error: ' .. tostring(err))
		end
	end

	local function remove(entry)
		for i, e in ipairs(pending) do
			if e == entry then
				table.remove(pending, i)
				break
			end
		end
		if entry.req_id and by_id[entry.req_id] == entry then
			by_id[entry.req_id] = nil
		end
	end

	-- Ends an entry with its one result. A repeat is ignored.
	local function finish(entry, ok, result)
		if entry.done then
			return
		end
		entry.done = true
		remove(entry)
		if waiting == entry then
			waiting = nil
		end
		if entry.on_result then
			call(entry.on_result, ok, result)
		end
	end

	local function notify(keys)
		for _, key in ipairs(keys) do
			local list = subscribers[key]
			if list then
				for _, sub in ipairs(copy(list)) do
					if sub.active then
						call(sub.fn, match_state[key], rev)
					end
				end
			end
		end
	end

	local function replace_state(new_rev, changed, full)
		local keys
		match_state, keys = Core.apply_changes(match_state, changed, full)
		rev = new_rev
		notify(keys)
	end

	-- Sends every entry that is unsent or marked for resend, in issue order.
	local function flush()
		if not synced or unsupported or not transport.live() then
			return
		end
		for _, e in ipairs(copy(pending)) do
			if not e.req_id then
				e.req_id, counter = Core.next_id(connection_id, counter)
				by_id[e.req_id] = e
			end
			if not e.sent or e.resend then
				local body = Core.request_body(deps.encode, Protocol.PROTOCOL_VERSION, e.req_id, e.type, e.payload_json)
				if not transport.send(Protocol.Op.REQUEST, body) then
					return
				end
				e.sent = true
				e.resend = nil
				e.resends = Core.resends_after_send(connected_time - e.born)
			end
		end
	end

	local function enqueue(entry)
		entry.born = connected_time
		entry.resends = 0
		pending[#pending + 1] = entry
		flush()
	end

	local function request_snapshot()
		if waiting then
			return
		end
		waiting = { type = 'snapshot', payload_json = '{}', internal = true }
		enqueue(waiting)
	end

	local function fail_all(reason)
		for _, e in ipairs(copy(pending)) do
			finish(e, false, { reason = reason })
		end
	end

	-- on_result(ok, result) is called once: ok -> { rev }, not ok -> { reason }.
	-- Returns a cancel function (the result is then `cancelled`). With no lobby
	-- or an old server the result comes on the next frame, never from inside
	-- this call. `type_` must be a string and `payload` nil or a table the JSON
	-- encoder accepts, else the result is `bad_payload`. The payload is encoded
	-- here, once: changing it after the call does not change what is sent.
	function self.request(type_, payload, on_result)
		local entry = { type = type_, on_result = on_result }
		local encoded_ok, payload_json = false, nil
		if type(type_) == 'string' and (payload == nil or type(payload) == 'table') then
			encoded_ok, payload_json = pcall(Core.encode_payload, deps.encode, payload)
		end
		entry.payload_json = payload_json
		if not encoded_ok then
			deferred[#deferred + 1] = { entry, false, { reason = 'bad_payload' } }
		elseif not transport.in_match() then
			deferred[#deferred + 1] = { entry, false, { reason = 'not_connected' } }
		elseif unsupported then
			deferred[#deferred + 1] = { entry, false, { reason = 'not_supported' } }
		else
			enqueue(entry)
		end
		return function()
			finish(entry, false, { reason = 'cancelled' })
			for i, d in ipairs(deferred) do
				if d[1] == entry then
					table.remove(deferred, i)
					break
				end
			end
		end
	end

	-- fn(value, rev) now, if the key is known, and on every change; returns unsubscribe.
	-- `value` is the live mirror table, shared with every other reader: treat it as
	-- read-only (copy it to change it).
	function self.on_state(key, fn)
		local sub = { fn = fn, active = true }
		subscribers[key] = subscribers[key] or {}
		table.insert(subscribers[key], sub)
		if match_state[key] ~= nil then
			call(fn, match_state[key], rev)
		end
		return function()
			sub.active = false
			local list = subscribers[key]
			for i, s in ipairs(list or {}) do
				if s == sub then
					table.remove(list, i)
					break
				end
			end
		end
	end

	-- The current value of a key and the revision (nil, nil before the first
	-- snapshot). Like on_state, the value is a read-only live mirror table.
	function self.get_state(key)
		return match_state[key], rev
	end

	-- The lobby's SNAPSHOT (join and every rejoin).
	function self.on_snapshot(data)
		local snap = Core.parse_snapshot(data)
		if not snap.supported then
			unsupported = true
			fail_all('not_supported')
			return
		end
		unsupported = false
		if snap.connection_id ~= connection_id then
			connection_id = snap.connection_id
			counter = 0
		end
		-- The snapshot is the whole state: a snapshot request still out is moot.
		if waiting then
			finish(waiting, false, { reason = 'cancelled' })
		end
		replace_state(snap.rev, snap.match, true)
		synced = true
		for _, e in ipairs(pending) do
			if e.sent then
				e.resend = true
			end
		end
		flush()
	end

	function self.on_answer(data)
		local entry = type(data) == 'table' and data.reqId and by_id[data.reqId]
		if not entry then
			return
		end
		if data.ok == true then
			finish(entry, true, { rev = data.rev })
		elseif data.reason == 'rate_limited' then
			-- Not stored by the server: stays pending and goes out again on schedule.
			return
		else
			-- A refusal the server recorded in the state names the rev it is in.
			finish(entry, false, { reason = data.reason or 'unknown', rev = data.rev, key = data.key })
		end
	end

	function self.on_state_push(data)
		if type(data) ~= 'table' or type(data.rev) ~= 'number' or type(data.changed) ~= 'table' then
			return
		end
		local verdict = Core.on_push(rev, data.rev, { full = data.full == true, waiting = waiting ~= nil })
		if verdict == 'apply' then
			replace_state(data.rev, data.changed, false)
		elseif verdict == 'apply_full' then
			waiting = nil
			replace_state(data.rev, data.changed, true)
		elseif verdict == 'snapshot' then
			request_snapshot()
		end
	end

	-- The socket dropped: sends wait for the rejoin snapshot.
	function self.on_dropped()
		synced = false
	end

	-- The seat is back; covers a snapshot that came before the socket counted as up.
	function self.on_rejoined()
		flush()
	end

	-- The lobby is gone (leave, close, kick, give-up).
	function self.on_closed()
		fail_all('not_connected')
		waiting = nil
		synced = false
		unsupported = false
		connection_id = nil
		counter = 0
		local keys = {}
		for k in pairs(match_state) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		match_state = {}
		rev = nil
		-- Subscribers hear (nil, nil) for each key that had a value.
		notify(keys)
	end

	-- Once per frame: resolves deferred results, resends on schedule, times out.
	function self.update()
		local t = deps.clock()
		-- A frame stall (window drag, a load) must not eat the deadline: answers
		-- buffered during it are read after the frame, so cap what it counts for.
		local dt = math.min(t - last_clock, MAX_FRAME_DT)
		last_clock = t
		if transport.live() and dt > 0 then
			connected_time = connected_time + dt
		end
		if #deferred > 0 then
			local batch = deferred
			deferred = {}
			for _, d in ipairs(batch) do
				finish(d[1], d[2], d[3])
			end
		end
		if #pending == 0 then
			return
		end
		local due = Core.due(pending, connected_time)
		for _, e in ipairs(due.timed_out) do
			finish(e, false, { reason = 'timeout' })
		end
		if #due.resend > 0 and synced and transport.live() then
			for _, e in ipairs(due.resend) do
				e.resend = true
			end
			flush()
		end
	end

	function self.pending_count()
		return #pending
	end

	return self
end

local instance = Shell.new({
	clock = function()
		return love.timer.getTime()
	end,
	encode = function(value)
		return MPAPI.json_encode(value)
	end,
	warn = function(message)
		MPAPI.sendWarnMessage(message)
	end,
	transport = {
		in_match = function()
			return MPAPI.networking.nakama_lobby.in_match()
		end,
		live = function()
			return MPAPI.networking.nakama_lobby.is_live()
		end,
		send = function(op, body)
			return MPAPI.networking.nakama_lobby.send_raw(op, body)
		end,
	},
})
MPAPI._internal.net = instance

-- Public surface.
MPAPI.request = instance.request
MPAPI.on_state = instance.on_state
MPAPI.get_state = instance.get_state

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function(...)
	instance.update()
	return MPAPI_update_ref(...)
end

return Shell
