-- Contract test: a log resumed after a crash can still give a log position and hash, taken
-- over the events the server already held (as the text it hashed) plus the events recorded
-- since. Run from the MPAPI repository root: luajit tests/recorder_resume_test.lua
local T = dofile('tests/support.lua')
local check = T.check

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
	match_log = function() end,
}
dofile('api/replay/recorder.lua')
local RLOG = MPAPI.replay
RLOG._force_active = true

-- hash_events: the hash of a downloaded log's first events is the hash the recorder took of them.
local downloaded = { { t = 1, opcode = 'play', args = { 1 } }, { t = 2, opcode = 'buy' } }
check(RLOG.hash_events(downloaded, 2) == '[[1,"play",[1]],[2,"buy",null]]', 'a downloaded log hashes like the recorder: ' .. tostring(RLOG.hash_events(downloaded, 2)))
check(RLOG.hash_events(downloaded, 1) == '[[1,"play",[1]]]', 'only the first count events are hashed')
check(RLOG.hash_events(downloaded, 0) == '[]', 'no events hash as an empty log')

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

-- Resumed over a log whose earlier events were only framing: no stray comma.
RLOG.resume_run({ { t = 1, opcode = 'match_manifest', args = {} } }, {}, '[]')
RLOG.record('buy', nil)
count, input = RLOG.log_position()
check(input == '[[2,"buy",null]]', 'a resume text of no events adds no comma: ' .. tostring(input))

-- A resumed log that ends sends a CHK over the whole log; one with no text does not.
local sent = {}
RLOG.register_broadcaster('chk_test', function() end)
MPAPI.get_current_lobby = function() return { code = 'X', mod_id = 'chk_test' } end
RLOG._broadcasters.chk_test = function(_, opcode, args) sent[#sent + 1] = { opcode = opcode, args = args } end
MPAPI.OPCODE = { END = 'end', CHK = 'chk' }
RLOG.resume_run(old, {}, '[[5,"play",[1]],[9,"buy",[]]]')
RLOG.record('sell', { 2 })
local carbon = RLOG.end_run({ result = 'win' })
check(carbon == '[[5,"play",[1]],[9,"buy",[]],[10,"sell",[2]]]', 'resumed end_run hashes the whole log: ' .. tostring(carbon))
check(sent[#sent].opcode == 'chk' and sent[#sent].args.carbon == carbon, 'and sends it as the CHK')
sent = {}
RLOG.resume_run(old, {})
RLOG.record('sell', { 2 })
check(RLOG.end_run({ result = 'win' }) == nil, 'no text, no hash')
check(sent[#sent].opcode == 'end', 'and the log ends with END only')

T.done('recorder_resume_test')
