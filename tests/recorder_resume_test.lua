-- Contract test: a log resumed after a crash can still give a log position and hash, taken
-- over the events the server already held (as the text it hashed) plus the events recorded
-- since. Run from the MPAPI repository root: luajit tests/recorder_resume_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

-- A stand-in encoder for the shapes used here, and a "hash" that returns its input so the
-- test can read what would have been hashed.
local function encode(v)
	if type(v) == 'string' then return '"' .. v .. '"' end
	if type(v) == 'table' then
		local out = {}
		for i, x in ipairs(v) do out[i] = encode(x) end
		return '[' .. table.concat(out, ',') .. ']'
	end
	return tostring(v)
end
package.loaded.json = { encode = encode }
love = {
	data = {
		hash = function(_, input) return input end,
		encode = function(_, _, value) return value end,
	},
}
sendTraceMessage = function() end
MPAPI = {
	get_current_lobby = function() return nil end,
	has_server_referee = function() return false end,
}
dofile('api/replay/recorder.lua')
local RLOG = MPAPI.replay
RLOG._force_active = true

-- A fresh log: the position is the event count, the input the canonical encoding.
RLOG.begin_run()
RLOG.record('play', { 1 })
RLOG.record('buy', nil)
local count, input = RLOG.log_position()
check(count == 2, 'count of a fresh log')
check(input == '[[1,"play",[1]],[2,"buy",null]]', 'hash input of a fresh log: ' .. tostring(input))

-- Resumed with the server's text of 2 earlier events: the position and the input go on from it.
local old = { { t = 5, opcode = 'play', args = { 1 } }, { t = 9, opcode = 'buy', args = {} } }
RLOG.resume_run(old, {}, '[[5,"play",[1]],[9,"buy",[]]]')
count, input = RLOG.log_position()
check(count == 2, 'a resumed log with nothing new is at the old count')
check(input == '[[5,"play",[1]],[9,"buy",[]]]', 'and hashes the old text as it is: ' .. tostring(input))
RLOG.record('sell', { 2 })
count, input = RLOG.log_position()
check(count == 3, 'a new event adds to the count')
check(input == '[[5,"play",[1]],[9,"buy",[]],[10,"sell",[2]]]', 'and follows the old text: ' .. tostring(input))

-- Resumed with an empty log.
RLOG.resume_run({}, {}, '[]')
RLOG.record('buy', nil)
count, input = RLOG.log_position()
check(count == 1 and input == '[[1,"buy",null]]', 'resume over an empty log: ' .. tostring(input))

-- Resumed without the server's text: no position, as before.
RLOG.resume_run(old, {})
check(RLOG.log_position() == nil, 'no text, no position')

print(string.format('recorder_resume_test: %d checks passed', checks))
