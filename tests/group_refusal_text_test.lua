-- Contract test: a group queue the server ended over a member's PvP version
-- (member_refused with reason version_mismatch) is worded with that member's
-- name. Run from the MPAPI repository root: luajit tests/group_refusal_text_test.lua
MPAPI = { _internal = {}, matchmaking = { group = {} }, networking = {} }
G = { localization = dofile('localization/en-us.lua') }
function localize(key)
	local misc = G.localization.misc
	return misc.dictionary[key] or misc.v_dictionary[key] or 'ERROR'
end
dofile('api/matchmaking/group/eligibility.lua')
local Group = MPAPI.matchmaking.group

local named = Group.member_refusal_from_server(
	{ userId = 'u1', reason = 'version_mismatch', mods = {} },
	{ u1 = 'Bob' }
)
local text = Group.refusal_text(named)
assert(text == 'Bob runs a different MultiplayerPvP version.', 'got: ' .. tostring(text))
print('ok   1 check')
