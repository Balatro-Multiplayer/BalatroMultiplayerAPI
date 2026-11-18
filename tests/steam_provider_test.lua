-- Contract test for the Steam provider hook (networking/steam.lua): one mod
-- can give the Steam id, name and tickets in place of the Steam client, and it
-- wins even while the Steam client runs. A provider that is not ready fails the
-- connect under one generic offline reason that carries the provider's message.
-- Run from the MPAPI repository root: luajit tests/steam_provider_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local warnings = {}
MPAPI = {
	networking = {},
	sendWarnMessage = function(msg)
		warnings[#warnings + 1] = msg
	end,
	sendDebugMessage = function() end,
	wrap_words = function(text)
		return { text }
	end,
}
localize = function(key)
	return key
end
dofile('domain/offline_reason.lua')
dofile('domain/connection_state.lua')
dofile('networking/steam.lua')
local steam = MPAPI.networking.steam
local R = MPAPI.OfflineReason

-- No provider, no Steam client.
G = {}
check(not steam.available(), 'no provider, no client: not available')
local reason = steam.unavailable_reason()
check(reason == R.STEAM_NOT_RUNNING, 'no provider, no client: Steam not running')
check(steam.get_steam_id() == nil, 'no provider, no client: no id')

-- No provider, Steam client running: the client answers as before.
G = {
	STEAM = {
		user = {
			getSteamID = function()
				return 111
			end,
		},
		friends = {
			getFriendPersonaName = function()
				return 'Client Name'
			end,
		},
	},
}
check(steam.available(), 'client runs: available')
check(steam.get_steam_id() == '111', 'client runs: client id')
check(steam.get_persona_name() == 'Client Name', 'client runs: client name')

-- A provider wins while the client runs.
local cancelled = {}
local function make_provider(mod, ready)
	local p = { mod = mod, is_ready = ready }
	p.ready = function()
		return p.is_ready
	end
	p.not_ready_message = function()
		return 'Log in to ' .. mod
	end
	p.get_steam_id = function()
		return mod .. '-id'
	end
	p.get_persona_name = function()
		return mod .. ' Name'
	end
	p.get_auth_ticket = function()
		return { ticket = mod .. 'ticket', handle = 7 }
	end
	p.cancel_auth_ticket = function(handle)
		cancelled[#cancelled + 1] = handle
	end
	return p
end

local first = make_provider('FirstMod', true)
check(steam.register_provider(first) == true, 'first registration is accepted')
check(steam.available(), 'ready provider: available')
check(steam.get_steam_id() == 'FirstMod-id', 'provider id wins over the client')
check(steam.get_persona_name() == 'FirstMod Name', 'provider name wins over the client')
local ticket = steam.get_auth_ticket()
check(ticket.ticket == 'FirstModticket' and ticket.handle == 7, 'provider ticket is used')
steam.cancel_auth_ticket(7)
check(cancelled[1] == 7, 'cancel goes to the provider')

-- A second registration is refused and the first stays.
local second = make_provider('SecondMod', true)
check(steam.register_provider(second) == false, 'second registration is refused')
check(#warnings == 1, 'refusal warns once')
check(warnings[1]:find('FirstMod', 1, true) and warnings[1]:find('SecondMod', 1, true), 'warning names both mods')
check(steam.get_steam_id() == 'FirstMod-id', 'first provider stays')

-- A not-ready provider: not available, generic reason, its own message.
first.is_ready = false
check(not steam.available(), 'not-ready provider: not available (client still runs)')
local why, message = steam.unavailable_reason()
check(why == R.STEAM_PROVIDER_NOT_READY, 'not-ready provider: generic offline reason')
check(message == 'Log in to FirstMod', 'not-ready provider: its message')

-- The menu shows the provider's message, not the generic line.
local lines = MPAPI.offline_reason_lines(R.STEAM_PROVIDER_NOT_READY, 'Log in to FirstMod')
check(#lines == 1 and lines[1] == 'Log in to FirstMod', 'menu shows the provider message')
lines = MPAPI.offline_reason_lines(R.STEAM_PROVIDER_NOT_READY, nil)
check(lines[1] == 'k_offline_steam_provider_not_ready', 'no message: generic line')
lines = MPAPI.offline_reason_lines(R.STEAM_PROVIDER_NOT_READY, '   ')
check(lines[1] == 'k_offline_steam_provider_not_ready', 'blank message: generic line')

-- The connection fails under that reason, with the message, for both logins.
dofile('networking/connection.lua')
local connection = MPAPI.networking.connection
for _, official in ipairs({ true, false }) do
	local got
	local c = connection.new({
		steam = steam,
		official = official,
		nakama_client = {},
	})
	c.on_state_change = function(state, context)
		got = { state = state, context = context }
	end
	c:connect()
	check(got and got.state == MPAPI.ConnectionState.DISCONNECTED, 'connect fails to disconnected')
	check(got.context.offline_reason == R.STEAM_PROVIDER_NOT_READY, 'connect fails under the provider reason')
	check(got.context.server_message == 'Log in to FirstMod', 'connect carries the provider message')
end

-- Ready again: the provider is used.
first.is_ready = true
check(steam.available(), 'ready again: available')

print('steam_provider_test: ' .. checks .. ' checks passed')
