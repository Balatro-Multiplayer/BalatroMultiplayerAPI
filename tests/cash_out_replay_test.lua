-- Contract test: a replayed Cash Out waits for the round evaluation instead of clicking at once.
-- Run from the MPAPI repository root: luajit tests/cash_out_replay_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local now = 0
love = { timer = { getTime = function() return now end } }
G = {
	STATES = { SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3, NEW_ROUND = 4, ROUND_EVAL = 5, SHOP = 6 },
	I = { UIBOX = {} },
	FUNCS = {},
}
local shop_built = false
MPAPI = {
	playback = { shop_is_built = function() return shop_built end },
	sendWarnMessage = function() end,
}
dofile('api/playback/shop.lua')
local P = MPAPI.playback

-- cashout_wait_over(button, round_eval, state, timed_out)
local S = G.STATES
check(P.cashout_wait_over(true, true, S.ROUND_EVAL, false), 'the button ends the wait')
check(P.cashout_wait_over(false, false, S.HAND_PLAYED, true), 'the timeout ends the wait')
check(not P.cashout_wait_over(false, false, S.HAND_PLAYED, false), 'the last hand is still being evaluated')
check(not P.cashout_wait_over(false, false, S.NEW_ROUND, false), 'a new round is not evaluated yet')
check(not P.cashout_wait_over(false, true, S.ROUND_EVAL, false), 'the round evaluation has no button yet')
check(P.cashout_wait_over(false, false, S.SHOP, false), 'already cashed out')

-- cash_out_when_ready: the driver pauses, the click waits for the button, the driver resumes in the shop.
local waiters = {}
local function wait_for(predicate, callback) waiters[#waiters + 1] = { predicate = predicate, callback = callback } end
local function poll()
	local pending = waiters
	waiters = {}
	for _, w in ipairs(pending) do
		if w.predicate() then w.callback() else waiters[#waiters + 1] = w end
	end
end
local log = {}
local driver = { pause = function() log[#log + 1] = 'pause' end, play = function() log[#log + 1] = 'play' end }
G.STATE = S.HAND_PLAYED
local button = { config = { button = 'cash_out' } }
G.FUNCS.cash_out = function(e) log[#log + 1] = (e == button) and 'click' or 'click without the button' end

P.cash_out_when_ready({ driver = driver }, wait_for, function() log[#log + 1] = 'before' end)
check(log[1] == 'pause' and #log == 1, 'the driver pauses first')
poll()
check(#log == 1, 'no click while the last hand is evaluated')
G.STATE = S.ROUND_EVAL
G.round_eval = {}
poll()
check(#log == 1, 'no click while the round evaluation has no button')
G.I.UIBOX = { { UIRoot = { children = { { config = { button = 'cash_out' }, children = {} } } } } }
G.I.UIBOX[1].UIRoot.children[1] = button
poll()
check(log[2] == 'before' and log[3] == 'click', 'the click uses the real button, after the hook: ' .. tostring(log[3]))
check(#log == 3, 'the driver waits for the shop')
G.STATE = S.SHOP
poll()
check(#log == 3, 'the driver waits for the shop cards')
shop_built = true
poll()
check(log[4] == 'play', 'the driver resumes once the shop is built')

-- A round that never reaches a Cash Out gives up after the timeout and clicks anyway.
log = {}
G.I.UIBOX = {}
G.round_eval = nil
G.STATE = S.HAND_PLAYED
G.FUNCS.cash_out = function() log[#log + 1] = 'click' end
P.cash_out_when_ready({ driver = driver }, wait_for)
poll()
check(#log == 1, 'still waiting')
now = now + P.CASHOUT_WAIT_SECONDS + 1
poll()
check(log[2] == 'click', 'the timeout clicks anyway')

print('cash_out_replay_test: ' .. checks .. ' checks passed')
