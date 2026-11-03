-- Replay log text line and structured args: nested lists, joker snapshot, idol roll,
-- deck snapshot. Run from the MPAPI repository root: luajit tests/replay_log_text_test.lua
package.path = 'lib/nakama/util/?.lua;' .. package.path
package.preload['json'] = function() return dofile('lib/nakama/util/json.lua') end
local traces = {}
function sendTraceMessage(m) traces[#traces + 1] = m end
love = { data = { hash = function(_, s) return s end, encode = function(_, _, s) return s end } }
MPAPI = {
  _internal = {},
  OPCODE = { END = 'end', CHK = 'chk' },
  get_current_lobby = function() return nil end,
  has_server_referee = function() return false end,
}
dofile('api/dev.lua')
dofile('lib/match_log.lua')
MPAPI._internal.dev_mod_loaded = true
dofile('api/replay/recorder.lua')
local RLOG = MPAPI.replay
local fails = 0
local function eq(name, got, want)
  if got ~= want then fails = fails + 1; print('FAIL ' .. name .. '\n  got:  ' .. tostring(got) .. '\n  want: ' .. tostring(want)) else print('ok   ' .. name) end
end
RLOG._force_active = true
local function line(opcode, args)
  RLOG.begin_run(); traces = {}
  RLOG.record(opcode, args)
  return traces[1]
end
local function body(l) return (l:gsub('^MP_RLOG: %d+ ', '')) end
eq('nil args', body(line('reroll', nil)), 'reroll')
eq('scalar', body(line('x', 0)), 'x 0')
eq('flat list token', body(line('buy', { 1, 2 })), 'buy 1 2')
eq('list token', body(line('discard', { { 1, 3, 5 } })), 'discard 1.3.5')
eq('play old shape', body(line('play', { { 1, 2 }, { { -1, 'pc', 'Hearts', 'King' }, { -2, 'pc', 'Spades', '10', 'e:m_glass' } } })),
  'play 1.2 -1.pc.Hearts.King,-2.pc.Spades.10.e:m_glass')
eq('play with jokers', body(line('play', { { 1 }, { { -1, 'pc', 'H', 'K' } }, { 'j_blueprint|foil', 'j_joker' } })),
  'play 1 -1.pc.H.K j_blueprint|foil.j_joker')
eq('play empty jokers', body(line('play', { { 1 }, { { 3 } }, {} })), 'play 1 3')
eq('select_blind', body(line('select_blind', { 0, 'bl_small' })), 'select_blind 0 bl_small')
eq('select_blind nil key', body(line('select_blind', { 0, nil })), 'select_blind 0')
eq('idol_roll', body(line('idol_roll', { '0.500000', 'QH', { 'KS4', 'QH3' } })), 'idol_roll 0.500000 QH KS4.QH3')
eq('deck_snapshot', body(line('deck_snapshot', { { 'HK', 'SA|e:m_glass|ed:foil' } })), 'deck_snapshot HK.SA|e:m_glass|ed:foil')
eq('3-deep', body(line('o', { { { { 1, 2 }, { 3 } }, { { 4 } } } })), 'o 1.2,3;4')
-- hash input unaffected by fmt: structured args kept as-is
RLOG.begin_run(); RLOG.record('select_blind', { 0, 'bl_big' })
eq('structured select_blind', RLOG._structured_events[1].args[2], 'bl_big')
-- old-format select_blind scalar still wraps
RLOG.begin_run(); RLOG.record('select_blind', 0)
eq('old select_blind wrap', RLOG._structured_events[1].args[1], 0)
-- joker_tokens / deck_tokens
G = { jokers = { cards = { { config = { center = { key = 'j_blueprint' } }, edition = { type = 'foil' } }, { config = { center = { key = 'j_joker' } } } } },
  playing_cards = { { base = { suit = 'Hearts', value = 'King' }, config = { center = { key = 'c_base' } } },
    { base = { suit = 'Spades', value = '10' }, config = { center = { key = 'm_glass' } }, edition = { type = 'foil' }, seal = 'Red' } } }
local jt = RLOG.joker_tokens()
eq('joker tokens', table.concat(jt, ','), 'j_blueprint|foil,j_joker')
eq('card ids untouched by joker_tokens', RLOG._next_card_id, 0)
eq('deck tokens', table.concat(RLOG.deck_tokens(), ','), 'HK,ST|e:m_glass|ed:foil|s:Red')
G = nil
eq('joker_tokens no G', #RLOG.joker_tokens(), 0)
-- a small roll sent as a fixed-point string encodes the same in Lua and in JS JSON
local json = require('json')
eq('small roll string encodes without exponent', json.encode({ string.format('%.6f', 0.00005) }), '["0.000050"]')
-- without the Dev mod the recorder still hashes and keeps the carbon buffer, but writes no log lines
MPAPI._internal.dev_mod_loaded = nil
RLOG.begin_run()
traces = {}
RLOG.record('reroll', nil)
eq('no log line without the Dev mod', #traces, 0)
eq('carbon buffer still filled', #RLOG._carbon_full > 0, true)
MPAPI._internal.dev_mod_loaded = true
os.exit(fails == 0 and 0 or 1)
