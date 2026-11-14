-- Contract test: a refused lobby:start_game reads in words and keeps the server's reason code
-- on err.reason. Run from the MPAPI repository root: luajit tests/start_refusal_text_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local dictionary = dofile('localization/en-us.lua').misc.dictionary
function localize(key)
	return dictionary[key] or 'ERROR'
end

local action_types = {}
MPAPI = {
	_internal = {},
	load_mpapi_file = function() end,
	ActionType = setmetatable({ obj_buffer = {} }, {
		__call = function(_, spec)
			action_types[spec.key] = spec
		end,
	}),
	ActionTypes = { mpapi_start_game = 'start' },
}
dofile('domain/error_kind.lua')
dofile('domain/result.lua')
dofile('api/action/builtin.lua')
local L = MPAPI._internal.lobby

-- A lobby whose server answers the start action with (err, result).
local function lobby_answering(err, result)
	return {
		_nakama = true,
		action = function()
			local builder = {}
			function builder:callback(fn)
				self.fn = fn
				return self
			end
			function builder:send()
				self.fn(nil, result, err)
			end
			return builder
		end,
	}
end

local function start(err, result)
	local got_err, got_started
	L.start_game(lobby_answering(err, result), {}, function(e, s)
		got_err, got_started = e, s
	end)
	return got_err, got_started
end

local mapped = {
	player_away = 'A player is disconnected. Wait for them to rejoin.',
	not_all_ready = 'Not everyone is ready.',
	too_few_players = 'Not enough players to start.',
	not_host = 'Only the host can start the game.',
	in_game = 'The game has already started.',
	group_queue = 'The lobby is queueing as a group.',
	bad_rules = 'This lobby is missing a rule setting. Create a new lobby.',
	mode_disabled = 'This game mode is turned off for now. Pick another mode.',
}
for reason, words in pairs(mapped) do
	local err = start(MPAPI.make_error(MPAPI.ErrorKind.ACTION_REJECTED, reason))
	check(err.message == words, reason .. ' reads in words')
	check(err.kind == MPAPI.ErrorKind.ACTION_REJECTED, reason .. ' stays ACTION_REJECTED')
	check(err.reason == reason, reason .. ' keeps its code on err.reason')
end

local passed = MPAPI.make_error(MPAPI.ErrorKind.ACTION_REJECTED, 'bad_params')
local err = start(passed)
check(err == passed and err.message == 'bad_params' and err.reason == nil, 'an unmapped reason passes through')

local other = MPAPI.make_error(MPAPI.ErrorKind.TIMEOUT or 'timeout', 'player_away')
err = start(other)
check(err == other and err.message == 'player_away', 'only a server refusal is mapped')

local started = { runId = 'r1' }
local got_err, got_started = start(nil, started)
check(got_err == nil and got_started == started, 'success passes started through')

-- A refused queue ticket or lobby create carries the bare code.
check(
	MPAPI.server_refusal_text('mode_disabled') == mapped.mode_disabled,
	'a mode_disabled queue or create refusal reads in words'
)

-- A refused queue ticket or lobby create shows its text as it is.
check(MPAPI.server_refusal_text('Queue banned') == 'Queue banned', 'other refusal text is shown as it is')
check(MPAPI.server_refusal_text(nil) == 'nil', 'a missing message is still shown')

print(('ok   %d checks'):format(checks))
