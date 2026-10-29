-- Contract test for a server QUEUE_CANCELLED: it names the queue by the bare
-- board name (no 'ranked:' prefix, like the ticket's mode), so it must end the
-- handle of a ranked queue whose game_mode is 'ranked:<board>'. Run from the
-- MPAPI repository root: luajit tests/queue_cancel_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = { _internal = {}, matchmaking = {}, networking = {} }
dofile('domain/standing.lua')
dofile('api/matchmaking/state.lua')
dofile('api/connection/moderation.lua')
local mm = MPAPI._internal.mm
local Moderation = MPAPI._internal.moderation

local ranked = { mod_id = 'MultiplayerPvP', game_mode = 'ranked:pvp_ranked_balanced' }
local casual = { mod_id = 'MultiplayerPvP', game_mode = 'pvp_casual' }
local other = { mod_id = 'MultiplayerSPDRN', game_mode = 'pvp_ranked_balanced' }
mm.handles = { casual, other, ranked }

check(mm.find_handle_by_mode('MultiplayerPvP', 'pvp_ranked_balanced') == ranked, 'a bare board name finds the ranked handle')
check(mm.find_handle_by_mode('MultiplayerPvP', 'pvp_casual') == casual, 'a casual handle is found by its mode')
check(mm.find_handle_by_mode('MultiplayerPvP', 'ranked:pvp_ranked_balanced') == ranked, 'the prefixed key still finds it')
check(mm.find_handle_by_mode('MultiplayerSPDRN', 'pvp_ranked_balanced') == other, 'the mod id is part of the match')
check(mm.find_handle_by_mode('MultiplayerPvP', 'nope') == nil, 'an unknown mode finds nothing')

local refusal = Moderation.standing_refusal_of({ code = 'version_mismatch' })
check(refusal and refusal.code == MPAPI.QueueRefusalCode.VERSION_MISMATCH, 'version_mismatch is a known refusal code')

print(('ok   %d checks'):format(checks))
