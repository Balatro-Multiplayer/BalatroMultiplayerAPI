-- Contract test: a replayed play or discard waits until the next hand is dealt.
-- Run from the MPAPI repository root: luajit tests/hand_ready_replay_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local now = 0
love = { timer = { getTime = function() return now end } }
G = {
	STATES = { SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3, NEW_ROUND = 4, ROUND_EVAL = 5, SHOP = 6 },
	hand = { cards = {} },
}
local S = G.STATES
MPAPI = {
	playback = { wait_gave_up = function() end },
	sendWarnMessage = function() end,
}
dofile('api/playback/hand.lua')
local P = MPAPI.playback

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
local function act() log[#log + 1] = 'act' end

-- The hand is dealt: the action runs at once, the driver is not touched.
G.STATE = S.SELECTING_HAND
G.hand.cards = { {}, {} }
P.with_hand_ready({ driver = driver }, act, wait_for)
check(#log == 1 and log[1] == 'act', 'a dealt hand runs the action at once')

-- A second play right after a first: the queue is empty, but the refill has not been drawn.
log = {}
G.STATE = S.HAND_PLAYED
G.hand.cards = {}
P.with_hand_ready({ driver = driver }, act, wait_for)
check(log[1] == 'pause' and #log == 1, 'the driver pauses while the hand is played')
poll()
check(#log == 1, 'no action while the hand is played')
G.STATE = S.DRAW_TO_HAND
poll()
check(#log == 1, 'no action while the refill is drawn')
G.STATE = S.SELECTING_HAND
poll()
check(#log == 1, 'no action while the refill has no cards yet')
G.hand.cards = { {}, {} }
poll()
check(log[2] == 'act' and log[3] == 'play', 'the action runs once the hand is dealt, then the driver resumes')

-- A play recorded after the replay already left the hand screen does not wait.
log = {}
G.STATE = S.SHOP
P.with_hand_ready({ driver = driver }, act, wait_for)
check(#log == 1 and log[1] == 'act', 'a screen without a hand runs the action at once (it warns by itself)')

-- A hand that never comes gives up after the timeout.
log = {}
G.STATE = S.DRAW_TO_HAND
G.hand.cards = {}
P.with_hand_ready({ driver = driver }, act, wait_for)
poll()
check(#log == 1, 'still waiting')
now = now + P.HAND_READY_TIMEOUT_SECONDS + 1
poll()
check(log[2] == 'act' and log[3] == 'play', 'the timeout runs the action and resumes')

print('hand_ready_replay_test: ' .. checks .. ' checks ok')
