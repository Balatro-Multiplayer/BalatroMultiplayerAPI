-- Setup (Nakama lobbies): the Draft and the votes a started game runs before
-- its run. The server holds every step, checks every ban, pick and vote, does
-- every roll and closes a step whose time is up (BalatroMultiplayerServer
-- nakama/src/actions/setup.ts). The host only starts each step; which step
-- comes next is the mod's business, read from the results.
--
-- The state is { open, results }:
--   open = nil | a Draft { kind = 'draft', id, pool, banned, order, first,
--     schedule, turn, remaining, actor, msLeft } | a vote { kind = 'vote', id,
--     options, voters, voted, msLeft }
--   results[id] = { kind = 'draft', survivors, banned } | { kind = 'vote',
--     option, counts }
-- Pool items are { key, stake?, ... }: the candidates the host sent, with the
-- stake the server rolled. A Draft's turn is 0-based (schedule[turn + 1]).
-- Listen for MPAPI.LobbyEvent.SETUP_CHANGED to re-render.
MPAPI.Setup = MPAPI.Setup or {}
local Setup = MPAPI.Setup

-- An older server relays an action it doesn't know, and a relay to the
-- server target fails (relay.ts, 'unknown_target').
local OLD_SERVER_REASON = 'unknown_target'

local function ask(lobby, key, params, cb)
	if not MPAPI.has_server_referee(lobby) then
		if cb then
			cb(MPAPI.make_error(MPAPI.ErrorKind.VALIDATION, 'needs a Nakama lobby'))
		end
		return
	end
	lobby:action(MPAPI.ActionTypes[key])
		:callback(function(_, result, err)
			if err and err.kind == MPAPI.ErrorKind.ACTION_REJECTED and err.message == OLD_SERVER_REASON then
				err = MPAPI.make_error(MPAPI.ErrorKind.SERVER_TOO_OLD, localize('k_mpapi_server_too_old'))
			end
			if cb then
				cb(err, result)
			end
		end)
		:send(nil, params)
end

function Setup.state(lobby)
	return lobby._game.setup
end

function Setup.open_step(lobby)
	return lobby._game.setup.open
end

function Setup.result(lobby, id)
	return lobby._game.setup.results[id]
end

-- Seconds until the open step's deadline (0 when nothing is open).
function Setup.seconds_left(lobby)
	local setup = lobby._game.setup
	if not (setup.open and setup.received_at) then
		return 0
	end
	local waited = love.timer.getTime() - setup.received_at
	return math.max(0, (setup.open.msLeft or 0) / 1000 - waited)
end

-- The open Draft's current turn ({ actor, action, count }), or nil.
function Setup.draft_turn(lobby)
	local open = lobby._game.setup.open
	if not (open and open.kind == 'draft') then
		return nil
	end
	return open.schedule[(open.turn or 0) + 1]
end

function Setup.is_my_turn(lobby)
	local open = lobby._game.setup.open
	return open ~= nil and open.kind == 'draft' and open.actor == lobby.player_id
end

function Setup.has_voted(lobby)
	local open = lobby._game.setup.open
	if not (open and open.kind == 'vote') then
		return false
	end
	for _, id in ipairs(open.voted or {}) do
		if id == lobby.player_id then
			return true
		end
	end
	return false
end

-- Host only. opts = { id, candidates = { { key, stake?, ... }, ... },
-- pool_size?, keep? (default 1), schedule? ({ { actor, action = 'ban' |
-- 'pick', count }, ... }), max_stake?, max_repeats? (how often one candidate
-- may sit in the pool, each time on its own stake), turn_seconds? }. Without a schedule,
-- single bans rotate through the players until `keep` tiles are left.
-- cb(err, result).
function Setup.start_draft(lobby, opts, cb)
	ask(lobby, 'mpapi_setup_draft', {
		id = opts.id,
		candidates = opts.candidates,
		poolSize = opts.pool_size,
		keep = opts.keep,
		schedule = opts.schedule,
		maxStake = opts.max_stake,
		maxRepeats = opts.max_repeats,
		turnSeconds = opts.turn_seconds,
	}, cb)
end

-- Host only. opts = { id, options = { key, ... }, seconds? }. cb(err, result).
function Setup.start_vote(lobby, opts, cb)
	ask(lobby, 'mpapi_setup_vote', {
		id = opts.id,
		options = opts.options,
		seconds = opts.seconds,
	}, cb)
end

-- The current actor's ban, or pick on a pick turn, of the pool item `key`.
function Setup.choose(lobby, key, cb)
	ask(lobby, 'mpapi_setup_choose', { key = key }, cb)
end

-- This player's one vote in the open vote.
function Setup.cast(lobby, option, cb)
	ask(lobby, 'mpapi_setup_cast', { option = option }, cb)
end

