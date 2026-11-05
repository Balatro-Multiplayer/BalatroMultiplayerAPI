-- Contract test: the Reconnect click joins the lobby the server holds now, not the one it named at login.
-- A server restart while the prompt is up moves the lobby to a new match.
-- Run from the MPAPI repository root: luajit tests/reconnect_prompt_seat_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

G = { FUNCS = {}, OVERLAY_MENU = nil }
create_UIBox_generic_options = function() return {} end
local current_reply = nil
local joined = nil
MPAPI = {
	ConnectionState = { CONNECTED = 'connected' },
	Standing = { VERIFIED = 'verified' },
	on_connection_state_change = function() end,
	sendWarnMessage = function() end,
	LobbyType = { PRIVATE = 'private' },
	ui_element = function() return { as_overlay = function() end } end,
	_internal = {
		lobby = {
			nakama_check_current = function(cb) cb(current_reply) end,
			nakama_leave_current = function(cb) cb() end,
		},
	},
	replay = { get_active_run = function(cb) cb(nil, { active = nil }) end },
	standing = { rejoin_refusal = function() return nil end },
	account_standing = function() return nil end,
	is_launcher_verified = function() return true end,
	create_reconnected_lobby = nil,
}
MPAPI._internal.create_reconnected_lobby = function(lobby_data, cb) joined = lobby_data end
MPAPI.lobby_reconnect = function() end
MPAPI.get_current_view = function() return 'x' end
dofile('ui/reconnect_prompt.lua')

local stale = { nakama = true, matchId = 'old-match', code = 'ABC123', modId = 'mod', type = 'private' }

-- the lobby moved to a new match after a server restart
current_reply = { nakama = true, matchId = 'new-match', code = 'ABC123', modId = 'mod', type = 'private' }
joined = nil
MPAPI._internal.reconnect_click(stale)
check(joined and joined.matchId == 'new-match', 'the click follows the lobby to its new match')

-- the lookup fails (server still starting): use what the prompt had
current_reply = nil
joined = nil
MPAPI._internal.reconnect_click(stale)
check(joined and joined.matchId == 'old-match', 'no answer: the prompt\'s own seat is used')

print('reconnect_prompt_seat_test: ' .. checks .. ' checks passed')
