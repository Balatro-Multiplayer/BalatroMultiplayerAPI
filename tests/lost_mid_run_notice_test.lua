-- Contract test: the server lost the match while a run is on screen -> the Connection Lost notice.
-- Run from the MPAPI repository root: luajit tests/lost_mid_run_notice_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local listener
local NL = {
	ClientOp = {},
	ServerOp = { SNAPSHOT = 100 },
	in_match = function() return false end,
	join = function(match_id, mod_id, l, cb) listener = l end,
	current = function(cb) cb(nil, nil) end,
}

local shown = {}
MPAPI = {
	ConnectionState = { DISCONNECTED = 'disconnected', CONNECTED = 'connected' },
	LobbyEvent = {},
	networking = { nakama_lobby = NL },
	_internal = {},
	get_nakama_session = function() return { user_id = 'me' } end,
	sendWarnMessage = function() end,
	match_log = function() end,
	is_forfeited_refusal = function() return false end,
	standing = { parse_rejoin_refusal = function() return nil end },
	show_connection_lost_notice = function() shown[#shown + 1] = 'connection_lost' end,
}
G = { STAGES = { RUN = 'run', MAIN_MENU = 'menu' }, STAGE = 'run' }
dofile('api/lobby/nakama.lua')
local L = MPAPI._internal.lobby
L.cleanup = function() end

local function attach_and_lose(stage, reason, gave_up)
	G.STAGE = G.STAGES[stage]
	shown = {}
	local lobby = { _nakama = true, _match_id = 'match-1', _nakama_ready = true, code = 'ABC123', mod_id = 'm', _fire = function() end }
	L.nakama_reattach(lobby)
	listener.lost(reason, gave_up)
	return #shown
end

check(attach_and_lose('RUN', 'Match not found', false) == 1, 'match gone in a run shows the notice')
check(attach_and_lose('MAIN_MENU', 'Match not found', false) == 0, 'match gone outside a run shows nothing')
check(attach_and_lose('RUN', 'some other error', false) == 0, 'another reason in a run shows nothing')
check(attach_and_lose('RUN', nil, false) == 0, 'no reason shows nothing')
check(attach_and_lose('RUN', 'Match not found', true) == 1, 'gave up in a run still shows exactly one notice')

T.done('lost_mid_run_notice_test')
