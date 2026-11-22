-- Contract test: a seat taken back because the same account joined from another process shows the
-- API's own notice and is never rejoined. Run from the MPAPI repository root:
-- luajit tests/opened_elsewhere_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local shown, notices, dropped = {}, {}, 0
localize = function(key) return 'text of ' .. key end
MPAPI = {
	_internal = { lobby = {} },
	LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
	sendWarnMessage = function() end,
	show_kicked_notice = function(kick) shown[#shown + 1] = kick end,
	show_forfeited_notice = function() shown[#shown + 1] = 'forfeited' end,
	show_notice = function(title_key, body) notices[#notices + 1] = { title_key = title_key, body = body } end,
}
local L = MPAPI._internal.lobby
L.cleanup = function() dropped = dropped + 1 end
dofile('api/lobby/events.lua')

local function new_lobby()
	return { player_id = 'me', _players = {}, _fire = function() end }
end

local function kick(lobby, who, reason)
	L.apply_event(lobby, { type = 'PLAYER_KICKED', playerId = who, data = reason and { reason = reason } or nil })
end

-- The lobby is dropped and the API's notice shows, not the kicked one.
local lobby = new_lobby()
kick(lobby, 'me', 'opened_elsewhere')
check(dropped == 1, 'the lobby is dropped')
check(#shown == 0, 'the kicked notice does not blame a player or moderator')
check(#notices == 1 and notices[1].body == 'text of k_opened_elsewhere', 'the API says the account was opened elsewhere')

-- Another reason, or another player, shows what it showed before.
shown, notices = {}, {}
lobby = new_lobby()
kick(lobby, 'me', 'host')
kick(lobby, 'other', 'opened_elsewhere')
check(#shown == 1 and shown[1].reason == 'host', 'an ordinary kick still shows its notice')
check(#notices == 0, 'an ordinary kick shows no opened-elsewhere notice')

T.done('opened_elsewhere_test')
