-- Contract test for the Steam provider hook (networking/steam.lua): one mod
-- can give the Steam id, name and tickets in place of the Steam client, and it
-- wins even while the Steam client runs. A provider that is not ready fails the
-- connect under one generic offline reason that carries the provider's message.
-- Run from the MPAPI repository root: luajit tests/steam_provider_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local warnings = {}
MPAPI = {
	_internal = { lobby = { nakama_connection_failed = function() end } },
	networking = {},
	sendWarnMessage = function(msg)
		warnings[#warnings + 1] = msg
	end,
	sendDebugMessage = function() end,
	wrap_words = function(text)
		return { text }
	end,
}
-- The connect hooks the lifecycle test below watches (api/connection/lifecycle.lua).
local calls = {}
local mpapi_ready = true
MPAPI.connection_state = { state = 'disconnected' }
MPAPI.connect = function()
	calls[#calls + 1] = 'connect'
end
MPAPI.disconnect = function()
	calls[#calls + 1] = 'disconnect'
end
MPAPI.get_last_opts = function()
	return nil
end
MPAPI.is_ready = function()
	return mpapi_ready
end
MPAPI.account_button = {
	update = function()
		calls[#calls + 1] = 'menu'
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

-- A provider that lacks a required function is refused, naming mod and field.
for _, field in ipairs({ 'ready', 'not_ready_message', 'get_steam_id', 'get_persona_name', 'get_auth_ticket', 'cancel_auth_ticket' }) do
	local incomplete = make_provider('PartialMod', true)
	incomplete[field] = nil
	local before = #warnings
	check(steam.register_provider(incomplete) == false, 'missing ' .. field .. ': registration refused')
	check(#warnings == before + 1, 'missing ' .. field .. ': warns once')
	check(warnings[#warnings]:find('PartialMod', 1, true) and warnings[#warnings]:find(field, 1, true), 'missing ' .. field .. ': warning names mod and field')
	check(steam.provider() == nil, 'missing ' .. field .. ': no provider is set')
end
warnings = {}

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

-----------------------------
-- Login after startup connects by itself
-----------------------------

local function count(name)
	local n = 0
	for _, c in ipairs(calls) do
		if c == name then
			n = n + 1
		end
	end
	return n
end

check(steam.provider() == first, 'provider() returns the registered provider')

-- Becoming ready while disconnected connects once, not on every later call.
first.is_ready = false
steam.provider_changed()
calls = {}
first.is_ready = true
steam.provider_changed()
check(count('connect') == 1, 'becoming ready while disconnected connects')
steam.provider_changed()
steam.provider_changed()
check(count('connect') == 1, 'later calls do not connect again')

-- A connected client is left alone, and a live connection is never touched.
first.is_ready = false
steam.provider_changed()
calls = {}
MPAPI.connection_state.state = MPAPI.ConnectionState.CONNECTED
first.is_ready = true
steam.provider_changed()
check(#calls == 0, 'a connected client is left alone')
-- The ready edge was spent while connected: no connect once it drops.
MPAPI.connection_state.state = MPAPI.ConnectionState.DISCONNECTED
steam.provider_changed()
check(count('connect') == 0, 'an edge seen while connected does not connect later')

-- Becoming ready again after a logout connects again.
first.is_ready = false
steam.provider_changed()
calls = {}
first.is_ready = true
steam.provider_changed()
check(count('connect') == 1, 'ready again after a logout connects again')

-- Before MPAPI's own startup has run, the startup does the first connect.
first.is_ready = false
steam.provider_changed()
mpapi_ready = false
calls = {}
first.is_ready = true
steam.provider_changed()
check(count('connect') == 0, 'before startup: no connect from provider_changed')
mpapi_ready = true

-- Startup waits for a settling provider, then connects when it settles.
first.is_ready = false
steam.provider_changed()
first.settled = function()
	return false
end
check(steam.begin_startup_wait() == true, 'settling provider: startup defers the first connect')
calls = {}
steam.provider_changed()
check(count('connect') == 0, 'still settling: no connect')
first.settled = function()
	return true
end
first.is_ready = true
steam.provider_changed()
check(count('connect') == 1, 'settled: the deferred first connect runs')
steam.provider_changed()
check(count('connect') == 1, 'the deferred connect runs once')

-- Settled with no login: startup is not deferred for a provider with no settled().
first.settled = nil
check(steam.begin_startup_wait() == false, 'no settled(): startup does not defer')
first.settled = function()
	return true
end
check(steam.begin_startup_wait() == false, 'settled provider: startup does not defer')

-- A provider that is ready at startup connects there, so its ready edge is spent.
first.is_ready = false
steam.provider_changed()
first.is_ready = true
steam.begin_startup_wait()
calls = {}
steam.provider_changed()
check(count('connect') == 0, 'startup connect covers a provider that is already ready')

T.done('steam_provider_test')
