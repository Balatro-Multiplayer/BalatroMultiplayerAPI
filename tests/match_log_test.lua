-- MPAPI.match_log gate: silent without the Dev mod, writes with it, and warnings
-- are never gated. Run from the MPAPI repository root: luajit tests/match_log_test.lua
local written = {}
local function record(kind)
	return function(msg, tag)
		written[#written + 1] = kind .. '|' .. tostring(msg) .. '|' .. tostring(tag)
	end
end
sendDebugMessage, sendInfoMessage, sendTraceMessage, sendWarnMessage = record('debug'), record('info'), record('trace'), record('warn')
MPAPI = { id = 'MultiplayerAPI', _internal = {} }
dofile('api/dev.lua')
dofile('lib/match_log.lua')
local fails = 0
local function eq(name, got, want)
	if got ~= want then
		fails = fails + 1
		print('FAIL ' .. name .. '\n  got:  ' .. tostring(got) .. '\n  want: ' .. tostring(want))
	else
		print('ok   ' .. name)
	end
end

eq('inactive by default', MPAPI.dev.active(), false)
MPAPI.match_log('debug', 'a')
MPAPI.match_log('info', 'b')
MPAPI.match_log('trace', 'c', 'T')
eq('no match lines without the Dev mod', #written, 0)
sendWarnMessage('w', 'X')
eq('warning passes without the Dev mod', written[1], 'warn|w|X')

written = {}
MPAPI.dev.set_server_defaults = nil
MPAPI._internal.dev_mod_loaded = true
eq('active once the Dev mod marks itself', MPAPI.dev.active(), true)
MPAPI.match_log('debug', 'a')
MPAPI.match_log('info', 'b')
MPAPI.match_log('trace', 'c', 'T')
eq('debug uses the mod id', written[1], 'debug|a|MultiplayerAPI')
eq('info', written[2], 'info|b|MultiplayerAPI')
eq('trace keeps the tag', written[3], 'trace|c|T')
sendWarnMessage('w', 'X')
eq('warning passes with the Dev mod', written[4], 'warn|w|X')
eq('bad level is a programmer error', pcall(MPAPI.match_log, 'warn', 'x'), false)

-- the flag is read at each call, so a Dev mod that loads later still counts
MPAPI._internal.dev_mod_loaded = nil
written = {}
MPAPI.match_log('debug', 'late')
eq('flag read per call', #written, 0)
os.exit(fails == 0 and 0 or 1)
