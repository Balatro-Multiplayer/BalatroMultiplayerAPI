-- Run from the MPAPI root: luajit tests/matchmaker_remove_reply_test.lua
-- lib/nakama/socket.lua: matchmaker_remove waits for the server's answer. NL.requeue reads that answer to
-- tell a withdrawn ticket from one that already matched; an instant answer let it drop the matched one.
package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local checks = 0
local function eq(actual, expected, message)
	checks = checks + 1
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
	end
end

local sent, deliver = {}, nil
local engine = {
	socket_create = function(_, on_message)
		local s = {}
		deliver = function(message) on_message(s, message) end
		return s
	end,
	socket_send = function(_, message) sent[#sent + 1] = message end,
}
local socket = require("nakama.socket").create({ config = {}, engine = engine })

local answer = nil
socket.matchmaker_remove("t1", function(result) answer = result end)
eq(answer, nil, "no answer before the server's")
local cid = sent[1] and sent[1].cid
eq(type(cid), "string", "the remove carries a cid")

deliver({ cid = cid, error = { code = 3, message = "Matchmaker ticket not found" } })
eq(answer and answer.error and answer.error.message, "Matchmaker ticket not found", "the server's refusal reaches the caller")

answer = nil
socket.matchmaker_remove("t2", function(result) answer = result end)
deliver({ cid = sent[2].cid })
eq(answer ~= nil and answer.error == nil, true, "a withdrawn ticket answers with no error")

print("matchmaker_remove_reply_test: ok (" .. checks .. " checks)")
