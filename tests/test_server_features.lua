-- Snapshot application also updates transport grace and setup on the release base.
MPAPI = {
	_internal = { lobby = { apply_setup = function() end } },
	networking = { nakama_lobby = { set_grace_seconds = function() end } },
}
dofile('api/lobby/nakama.lua')
local lobby = { player_id = 'a', _players = {}, _game = {} }
local apply = MPAPI._internal.lobby.apply_snapshot
apply(lobby, { hostId = 'a', serverFeatures = { shared_pvp_rules = 1 } }, false)
assert(lobby.server_features.shared_pvp_rules == 1, 'Server capability reaches the lobby')
apply(lobby, { hostId = 'a', metadata = { serverFeatures = { shared_pvp_rules = 1 } } }, false)
assert(next(lobby.server_features) == nil, 'Metadata cannot spoof missing server capability')
apply(lobby, { hostId = 'a', serverFeatures = 'invalid' }, false)
assert(next(lobby.server_features) == nil, 'Malformed capabilities fail closed')
print('Server features: 3 checks passed')
