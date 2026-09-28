-- MPAPI's authoritative actions: the lobby flow every gamemode shares, run by
-- the Nakama lobby's server (BalatroMultiplayerServer nakama/src/actions/
-- registry.ts) instead of a host client. Each on_receive only ever sees the
-- server's result (from == MPAPI.ACTION_FROM_SERVER; see dispatch.lua).
--
-- Mods use the lobby methods (lobby:set_ready, lobby:start_game) and listen
-- for PLAYER_READY_CHANGED / GAME_STARTED rather than touching these keys.
MPAPI.load_mpapi_file('api/action/registry.lua')

MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

-- Result params: { playerId, ready }.
MPAPI.ActionType({
	key = 'mpapi_ready',
	authoritative = true,
	parameters = {
		{ key = 'ready', type = 'boolean', required = true },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.playerId) == 'string') then
			return
		end
		lobby._game.ready[result.playerId] = result.ready == true or nil
		MPAPI.set_player_ready(lobby, result.playerId, result.ready == true)
	end,
})

-- Result params: { seed, stake, options }.
MPAPI.ActionType({
	key = 'mpapi_start_game',
	authoritative = true,
	parameters = {
		{ key = 'stake', type = 'number' },
		{ key = 'options', type = 'table' },
	},
	on_receive = function(_, _, result)
		local lobby = MPAPI.get_current_lobby()
		if not (lobby and type(result) == 'table' and type(result.seed) == 'string') then
			return
		end
		L.apply_game_started(lobby, result)
	end,
})

L.apply_game_started = function(lobby, started)
	lobby._game.started = { seed = started.seed, stake = started.stake, options = started.options }
	lobby._game.ready = {}
	lobby:_fire(MPAPI.LobbyEvent.GAME_STARTED, lobby._game.started)
end

-- Without a server there's nobody to referee: cb gets an error straight away.
local function needs_nakama(lobby, cb)
	if lobby._nakama then
		return false
	end
	if cb then
		cb(MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'needs a Nakama lobby'))
	end
	return true
end

-- cb(err) once the server has taken (err == nil) or refused the change.
L.set_ready = function(lobby, ready, cb)
	if needs_nakama(lobby, cb) then
		return
	end
	lobby:action(MPAPI.ActionTypes.mpapi_ready)
		:callback(function(_, _, err)
			if cb then
				cb(err)
			end
		end)
		:send(nil, { ready = ready and true or false })
end

-- Host only, once everyone else is ready. opts = { stake?, options? };
-- cb(err, started) where started = { seed, stake, options }.
L.start_game = function(lobby, opts, cb)
	if needs_nakama(lobby, cb) then
		return
	end
	opts = opts or {}
	lobby:action(MPAPI.ActionTypes.mpapi_start_game)
		:callback(function(_, result, err)
			if cb then
				cb(err, result)
			end
		end)
		:send(nil, { stake = opts.stake, options = opts.options })
end
