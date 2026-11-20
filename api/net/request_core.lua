-- Pure core of the request/answer layer: the resend schedule, revision gap
-- rules, request ids and the shared-state merge. No G, love, os, socket or
-- lobby reads; "now" is passed in. The shell (request_shell.lua) owns the
-- pending list, the clock and the socket, and does what this returns.
local M = {}

-- Seconds after a request was issued (connected time only) at which it is sent again.
M.RESEND_AT = { 0.5, 1.5, 3.5, 7.5, 11.5 }
-- Connected seconds without an answer after which a request ends with `timeout`.
M.DEADLINE = 15

-- entries: array in issue order of { born, sent, resends, req_id? }. `born` and
-- `now` share one clock (the shell's connected-time clock). Returns
-- { resend = {entry...}, timed_out = {entry...} }, each in the order of `entries`.
-- Only an entry already sent once is resent; every entry can time out.
function M.due(entries, now)
	local out = { resend = {}, timed_out = {} }
	for _, e in ipairs(entries) do
		local age = now - e.born
		if age >= M.DEADLINE then
			out.timed_out[#out.timed_out + 1] = e
		elseif e.sent and M.RESEND_AT[(e.resends or 0) + 1] and age >= M.RESEND_AT[(e.resends or 0) + 1] then
			out.resend[#out.resend + 1] = e
		end
	end
	return out
end

-- How many schedule points an entry of this age has passed: its `resends` after
-- a send now, so a send never makes the next frame resend it again.
function M.resends_after_send(age)
	local n = 0
	for _, at in ipairs(M.RESEND_AT) do
		if age >= at then
			n = n + 1
		end
	end
	return n
end

-- What to do with a STATE push of push_rev when the local revision is local_rev
-- (nil before the first snapshot). opts = { full = bool, waiting = bool } where
-- waiting is "a snapshot request is out and unanswered".
--   'apply_full' a full STATE with rev >= local (even while waiting; ends the wait)
--   'apply'      the next revision
--   'drop'       already known
--   'ignore'     a gap, or any non-full push, while waiting for the snapshot
--   'snapshot'   a gap: ask for a snapshot
function M.on_push(local_rev, push_rev, opts)
	opts = opts or {}
	if opts.full then
		if local_rev == nil or push_rev >= local_rev then
			return 'apply_full'
		end
		return 'drop'
	end
	if local_rev == nil or push_rev <= local_rev then
		return 'drop'
	end
	if opts.waiting then
		return 'ignore'
	end
	if push_rev == local_rev + 1 then
		return 'apply'
	end
	return 'snapshot'
end

-- reqId of the next request on this connection, and the counter to keep.
function M.next_id(connection_id, counter)
	return connection_id .. ':' .. (counter + 1), counter + 1
end

-- The REQUEST body as JSON. An empty payload must stay an object ({}), which a
-- plain encoder writes as an array, so the payload is encoded here by hand.
-- `encode` is the JSON encoder.
function M.request_json(encode, version, req_id, type_, payload)
	return M.request_body(encode, version, req_id, type_, M.encode_payload(encode, payload))
end

-- The payload as JSON; an empty one is {} (an encoder writes it as []). Throws
-- on a table the encoder refuses.
function M.encode_payload(encode, payload)
	return (payload == nil or next(payload) == nil) and '{}' or encode(payload)
end

-- request_json with the payload already encoded.
function M.request_body(encode, version, req_id, type_, payload_json)
	return '{"v":' .. encode(version) .. ',"reqId":' .. encode(req_id) .. ',"type":' .. encode(type_) .. ',"payload":' .. payload_json .. '}'
end

local function deep_equal(a, b)
	if a == b then
		return true
	end
	if type(a) ~= 'table' or type(b) ~= 'table' then
		return false
	end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end
M.deep_equal = deep_equal

-- Merges a STATE's `changed` into `state` and returns the new state and the
-- sorted keys whose value differs. `full` replaces the whole state: a key absent
-- from `changed` is gone. Neither argument is modified. JSON null decodes to an
-- absent key, so a non-full STATE cannot remove a key: only a full STATE or a
-- snapshot does.
function M.apply_changes(state, changed, full)
	local new_state = {}
	if not full then
		for k, v in pairs(state) do
			new_state[k] = v
		end
	end
	for k, v in pairs(changed) do
		new_state[k] = v
	end
	local keys = {}
	for k, v in pairs(new_state) do
		if not deep_equal(v, state[k]) then
			keys[#keys + 1] = k
		end
	end
	for k in pairs(state) do
		if new_state[k] == nil then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys)
	return new_state, keys
end

-- Reads the layer's fields out of a SNAPSHOT body. A snapshot with no `protocol`
-- (or no connectionId to build request ids from) comes from a server that does
-- not know requests.
function M.parse_snapshot(snapshot)
	if type(snapshot) ~= 'table' or tonumber(snapshot.protocol) == nil or type(snapshot.connectionId) ~= 'string' then
		return { supported = false }
	end
	return {
		supported = true,
		rev = tonumber(snapshot.rev) or 0,
		connection_id = snapshot.connectionId,
		match = type(snapshot.match) == 'table' and snapshot.match or {},
	}
end

return M
