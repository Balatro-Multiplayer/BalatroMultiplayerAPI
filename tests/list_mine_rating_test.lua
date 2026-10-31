-- Contract test: MPAPI.replay.list_mine passes on the caller's rating result
-- from runs_mine, and nil for a run that wasn't rated. Run from the MPAPI
-- repository root: luajit tests/list_mine_rating_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local reply
MPAPI = { networking = { nakama_lobby = {} } }
MPAPI.networking.nakama_lobby.rpc = function(id, body, callback)
	callback(nil, reply)
end
dofile('api/replay/api.lua')

reply = {
	runs = {
		{ runId = 'ranked', code = 'ABCDEF', status = 'agreed', rating = { delta = 12, newRating = 1012, isPlacement = false } },
		{ runId = 'casual', code = 'GHIJKL', status = 'agreed', rating = nil },
	},
	cursor = '',
}
local runs
MPAPI.replay.list_mine({}, function(err, data)
	runs = data.runs
end)
check(runs[1].rating and runs[1].rating.delta == 12, 'a rated run keeps its rating change')
check(runs[2].rating == nil, 'an unrated run has no rating')

print(('ok   %d checks'):format(checks))
