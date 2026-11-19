-- A rejoin refused while the launcher verdict is pending: the lobby waits for a
-- fresh verdict through MPAPI.rejoin_recheck.run, retries once on a good or
-- late verdict, and does not retry on a verdict that failed. Run from the MPAPI
-- repository root: luajit tests/rejoin_wait_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local now = 0
love = { timer = { getTime = function() return now end } }
local joins, rpcs = 0, 0
local join_error
local function new_socket()
	local s = {}
	function s.on_match_data() end
	function s.on_matchmaker_matched() end
	function s.on_party() end
	function s.on_party_presence_event() end
	function s.on_party_leader() end
	function s.on_notifications() end
	function s.on_error() end
	function s.on_disconnect() end
	function s.disconnect() end
	function s.connect(cb) cb(true) end
	function s.match_join(_, _, _, cb)
		joins = joins + 1
		if join_error then
			cb({ error = true, message = join_error })
		else
			cb({})
		end
	end
	return s
end
local client = {
	create_socket = new_socket,
	rpc_func = function(_, _, _, cb)
		rpcs = rpcs + 1
		cb({ payload = '{}' })
	end,
}
local conn = {
	player_id = 'a',
	nakama_client = client,
	with_session = function(_, cb) cb({}) end,
}
MPAPI = {
	networking = {},
	get_connection = function() return conn end,
	collect_installed_mods = function() return {} end,
	json_encode = function() return '{}' end,
	json_decode = function() return {} end,
	sendWarnMessage = function() end,
}
dofile('networking/nakama_lobby.lua')
local NL = MPAPI.networking.nakama_lobby

local function run_for(seconds)
	for _ = 1, seconds * 10 do
		now = now + 0.1
		NL.update()
	end
end

local function drop_with(listener_extra)
	local lost, waited, retried = nil, 0, nil
	local listener = {
		data = function() end,
		lost = function(reason) lost = reason end,
		refused_wait = function(err, retry)
			waited = waited + 1
			retried = retry
			return true
		end,
	}
	for k, v in pairs(listener_extra or {}) do listener[k] = v end
	join_error = nil
	NL.join('m1', 'pvp', listener, function() end)
	join_error = 'verification_pending'
	NL._drop_socket()
	run_for(5)
	return function() return lost, waited, retried end
end

-- The held refusal retries once when the listener calls retry().
local state = drop_with()
local lost, waited, retry = state()
check(waited == 1 and lost == nil, 'a refused rejoin is held for the listener')
local joins_held = joins
join_error = nil
retry()
run_for(5)
check(joins == joins_held + 1, 'retry() asks the server again once')
check(NL._current_match_id() == 'm1', 'the retry keeps the lobby')
NL.reset()

-- retry(true) takes the refusal as final: no second join, the lobby is lost.
state = drop_with()
lost, waited, retry = state()
local joins_final = joins
retry(true)
run_for(5)
lost = state()
check(joins == joins_final, 'retry(true) does not join again')
check(lost == 'verification_pending', 'retry(true) ends the lobby with the refusal')
print(('ok   %d checks'):format(checks))
