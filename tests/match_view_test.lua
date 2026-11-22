-- Contract test for the match view and server features in api/lobby/nakama.lua.
local T = dofile('tests/support.lua')
local check = T.check

-- The API carries a mod's inputs up and its view down, and knows nothing of what they hold. A
-- mod that registers nothing sees no change.
T.part(function()
	local sent = {}
	local warnings = 0
	local socket_up = true
	MPAPI = {
		_internal = { lobby = {} },
		sendWarnMessage = function() warnings = warnings + 1 end,
		networking = { nakama_lobby = {
			ClientOp = { INPUT = 8 },
			send = function(op, tbl)
				if not socket_up then return false end
				sent[#sent + 1] = { op = op, body = tbl }
				return true
			end,
		} },
	}
	dofile('api/lobby/nakama.lua')
	local L = MPAPI._internal.lobby

	-- No handler: a view is ignored without error.
	L.deliver_match_view({ mod_id = 'nobody' }, { n = 1 })
	check(warnings == 0, 'a view for a mod with no handler is ignored')

	-- A handler gets the lobby and the view, only for its own mod.
	local got
	MPAPI.on_match_view('pvp', function(lobby, view) got = { lobby, view } end)
	local lobby = { mod_id = 'pvp' }
	L.deliver_match_view(lobby, { n = 2 })
	check(got and got[1] == lobby and got[2].n == 2, 'the owning mod gets the view')
	got = nil
	L.deliver_match_view({ mod_id = 'speedrun' }, { n = 3 })
	check(got == nil, 'another mod gets nothing')
	L.deliver_match_view(lobby, 'not a table')
	check(got == nil, 'a view that is not a table is dropped')

	-- A handler that errors is reported and does not stop the lobby.
	MPAPI.on_match_view('pvp', function() error('broken') end)
	L.deliver_match_view(lobby, { n = 4 })
	check(warnings == 1, 'a failing handler is warned about')

	-- Inputs go out as op 8, and a down socket says so.
	check(MPAPI.send_match_input(lobby, { kind = 'ready' }) and sent[1].op == 8 and sent[1].body.kind == 'ready', 'input sent as op 8')
	socket_up = false
	check(not MPAPI.send_match_input(lobby, { kind = 'ready' }), 'socket down: not sent')
	socket_up = true
	check(not MPAPI.send_match_input({ _destroyed = true }, { kind = 'ready' }), 'a dropped lobby sends nothing')
	check(not MPAPI.send_match_input(lobby, 'text'), 'an input must be a table')
	check(#sent == 1, 'only the one good input left')
end)

-- The wiring the lobby's callers rely on, through the real transport constants and the real
-- public entry point: op 114 reaches the mod's view function, and the save a rejoin will load
-- reaches the join.
T.part(function()
	love = { timer = { getTime = function() return 0 end } }
	MPAPI = {
		_internal = { lobby = {} },
		networking = {},
		LobbyEvent = {},
		sendWarnMessage = function() end,
		match_log = function() end,
		get_connection = function() return {} end,
		get_nakama_session = function() return { user_id = 'me' } end,
	}
	dofile('networking/nakama_lobby.lua')
	local NL = MPAPI.networking.nakama_lobby
	local joins = {}
	NL.join = function(match_id, mod_id, listener, _, save_to_load)
		joins[#joins + 1] = { match_id = match_id, mod_id = mod_id, listener = listener, save_to_load = save_to_load }
	end
	dofile('api/lobby/nakama.lua')
	dofile('api/lobby/public.lua')
	MPAPI._internal.lobby.create_object = function(fields)
		fields._game = {}
		fields._fire = function() end
		return fields
	end

	-- A detached lobby is joined with the save, and its listener carries op 114 to the mod's view function.
	local save = { tag = 'the save' }
	local lobby = MPAPI._internal.create_detached_lobby({ matchId = 'm1', modId = 'pvp', code = 'C' }, function() end, save)
	check(#joins == 1 and joins[1].match_id == 'm1' and joins[1].mod_id == 'pvp', 'the lobby joins its match')
	check(joins[1].save_to_load == save, 'the save handed to create_detached_lobby reaches the join')

	local got
	MPAPI.on_match_view('pvp', function(l, view) got = { l, view } end)
	joins[1].listener.data(NL.ServerOp.VIEW, { n = 7 })
	check(got and got[1] == lobby and got[2].n == 7, 'op 114 reaches the owning mod through the listener')

	-- No save: the join is given none.
	MPAPI._internal.create_detached_lobby({ matchId = 'm2', modId = 'pvp', code = 'D' }, function() end, nil)
	check(joins[2].save_to_load == nil, 'with no save the join is given none')
end)

-- A snapshot carries the server capabilities onto the lobby, and a malformed value becomes an
-- empty table.
T.part(function()
	MPAPI = {
		_internal = { lobby = { apply_setup = function() end, adopt_log_seq = function() end, apply_ready_list = function() end } },
		plain_letters = function(s) return s end,
		networking = { nakama_lobby = { set_grace_seconds = function() end } },
	}
	dofile('api/lobby/nakama.lua')
	local lobby = { player_id = 'a', _players = {}, _game = {} }
	local apply = MPAPI._internal.lobby.apply_snapshot
	apply(lobby, { hostId = 'a', serverFeatures = { shared_pvp_rules = 2, almanac_draft = 1 } }, false)
	check(lobby.server_features.shared_pvp_rules == 2, 'Four-rule server capability reaches the lobby')
	check(lobby.server_features.almanac_draft == 1, 'Almanac draft capability reaches the lobby')
	apply(lobby, { hostId = 'a', metadata = { serverFeatures = { shared_pvp_rules = 2, almanac_draft = 1 } } }, false)
	check(next(lobby.server_features) == nil, 'Metadata cannot spoof missing server capability')
	apply(lobby, { hostId = 'a', serverFeatures = 'invalid' }, false)
	check(next(lobby.server_features) == nil, 'Malformed capabilities fail closed')
end)

T.done('match_view_test')
