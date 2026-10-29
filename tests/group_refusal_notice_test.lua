-- Contract test: a group queue the server refuses or ends over a member
-- (member_refused, any reason) shows one named notice to every client that is
-- not that member, and the host's open-time refusal shows exactly one.
-- Run from the MPAPI repository root: luajit tests/group_refusal_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = { _internal = {}, matchmaking = {}, networking = {} }
G = { localization = dofile('localization/en-us.lua') }
function localize(key)
	local misc = G.localization.misc
	return misc.dictionary[key] or misc.v_dictionary[key] or 'ERROR'
end
MPAPI.sendDebugMessage = function() end
MPAPI.sendWarnMessage = function() end
MPAPI.ConnectionState = { CONNECTED = 'connected' }
MPAPI.ErrorKind = { SERVER = 'server', VALIDATION = 'validation' }
MPAPI.make_error = function(kind, message)
	return { kind = kind, message = message }
end
MPAPI.MatchmakingEvent = { QUEUED = 'queued', LEFT = 'left', ERROR = 'error' }
MPAPI.LobbyType = { RANKED = 'ranked' }
MPAPI.standing = { queue_refusal = function() end, mod_names = function(m) return m end, format_mods = function() return '' end }
MPAPI.Standing = { NONE = 'none' }
MPAPI.account_standing = function() end
MPAPI.QueueKind = { CASUAL = 'casual' }
MPAPI.is_launcher_verified = function() return true end

local notices, overlays = {}, {}
MPAPI.show_notice = function(title_key, body)
	notices[#notices + 1] = { title_key = title_key, body = body }
end
MPAPI.show_standing_refusal = function(refusal)
	overlays[#overlays + 1] = refusal
end

local rpc_reply
MPAPI.networking.nakama_lobby = {
	party_create = function(_, cb) cb(nil, { party_id = 'p1', presences = {} }) end,
	party_leave = function() end,
	expect_ticket = function() end,
	after = function() end,
	set_party_listener = function() end,
	rpc = function(_, _, cb) cb(nil, rpc_reply) end,
}
MPAPI._internal.mm = {
	handles = {},
	remove_handle = function() end,
}

dofile('api/matchmaking/handle.lua')
dofile('api/matchmaking/group/eligibility.lua')
dofile('api/matchmaking/group/queue.lua')
local Group = MPAPI.matchmaking.group
MPAPI.matchmaking._nakama_ticket = function()
	return { min_count = 2, max_count = 8, query = '*', strings = { mode = 'pvp_nemesis' } }
end

local function lobby(my_id, host)
	local players = {
		{ id = 'host', displayName = 'Host', standing = 'valid' },
		{ id = 'bob', displayName = 'Bob', standing = 'valid' },
		{ id = 'cy', displayName = 'Cy', standing = 'valid' },
	}
	return {
		code = 'ABCD',
		player_id = my_id,
		is_host = host,
		type = 'private',
		get_players = function() return players end,
		is_game_started = function() return false end,
	}
end

local function reset()
	notices, overlays = {}, {}
	Group.last_end = nil
end

-- A member the server ended the matched group over, seen by another member.
reset()
local mine = lobby('cy', false)
Group._on_view(mine, {
	phase = 'idle',
	reason = 'member_refused',
	partyId = 'p1',
	homeCode = 'ABCD',
	refused = { userId = 'bob', reason = 'version_mismatch', mods = {} },
})
check(#notices == 1, 'another member gets one notice, got ' .. #notices)
check(notices[1].title_key == 'k_group_queue_failed_title', 'the group notice title')
check(notices[1].body == 'Bob runs a different MultiplayerPvP version.', 'named notice: ' .. tostring(notices[1].body))
check(#overlays == 0, 'only the refused member gets the overlay')

-- The refused member sees the overlay, not the notice.
reset()
Group._on_view(lobby('bob', false), {
	phase = 'idle',
	reason = 'member_refused',
	partyId = 'p1',
	homeCode = 'ABCD',
	refused = { userId = 'bob', reason = 'version_mismatch', mods = {} },
})
check(#overlays == 1, 'the refused member gets the overlay')
check(#notices == 0, 'the refused member gets no second notice')

-- Any reason is named, not only version.
reset()
Group._on_view(lobby('cy', false), {
	phase = 'idle',
	reason = 'member_refused',
	partyId = 'p1',
	homeCode = 'ABCD',
	refused = { userId = 'bob', reason = 'mods_not_allowed', mods = { 'x' } },
})
check(#notices == 1, 'a mods refusal is also shown')

-- Other end reasons show no notice.
reset()
Group._on_view(lobby('cy', false), { phase = 'idle', reason = 'cancelled', partyId = 'p1', homeCode = 'ABCD' })
check(#notices == 0, 'a cancel shows no notice')

-- The host's open-time refusal shows one notice, and its handle errors once.
reset()
rpc_reply = { refused = { code = 'member_refused', userId = 'bob', reason = 'version_mismatch', mods = {} } }
local errors = 0
MPAPI.get_current_lobby = function() return lobby('host', true) end
MPAPI.get_connection = function() return { get_state = function() return 'connected' end } end
local handle = Group.queue({ mod_id = 'MultiplayerPvP', game_mode = 'pvp_nemesis', min_players = 2, max_players = 4 })
check(handle, 'the open starts')
check(#notices == 1, 'the host open refusal shows one notice, got ' .. #notices)
check(notices[1].body == 'Bob runs a different MultiplayerPvP version.', 'host notice names the member')

print(('ok   %d checks'):format(checks))
