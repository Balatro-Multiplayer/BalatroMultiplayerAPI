--[[
  Ban-pick select-and-confirm test.

  Feature: instead of a per-card instant BAN button, clicking a deck marks it
  (raises + tag) and a Confirm button commits the whole selection. The selection
  model is pure (BP._selection); Confirm loops BP.request_ban over the marks, so
  the engine and networking are untouched.

  Covers: the toggle contract (add/remove/swap-at-cap-1/block-at-cap-N),
  needed() across ban/pick/complete steps, prune() against state broadcasts,
  the Confirm handler (correct count commits, wrong count no-ops, off-turn
  no-ops), and a full draft ending in on_complete.

  Run from the repo root:
    luajit dev/test_banpick_selection.lua
]]

-- ── Stubs to load the real module ───────────────────────────────────────────
MPAPI = {}
G = {
	FUNCS = {},
	C = { GREEN = 'green', MULT = 'mult', BLUE = 'blue', WHITE = 'white', BLACK = 'black', CLEAR = 'clear', UI = { BACKGROUND_INACTIVE = 'inactive', TEXT_LIGHT = 'light' } },
}

dofile('api/ban_pick.lua')
local BP = MPAPI.BanPick
local SEL = BP._selection

-- Fake lobby: host + one guest. ActionTypes empty => broadcast_state no-ops.
MPAPI.ActionTypes = {}
local LOBBY = {
	is_host = true,
	player_id = 'host',
	get_players = function(_self)
		return { { id = 'host' }, { id = 'guest' } }
	end,
}
MPAPI.get_current_lobby = function()
	return LOBBY
end

local POOL = { 'b_red', 'b_blue', 'b_yellow', 'b_green' }
local completed = nil

-- Start a fresh draft: host bans 2, guest bans 1 (4 - 3 = 1 survivor).
local function start_draft(schedule)
	completed = nil
	BP.start(LOBBY, {
		build_pool = function() return { unpack(POOL) } end,
		schedule = schedule,
		state_action = 'test_state',
		ban_action = 'test_ban',
		on_refresh = function() end,
	}, function(survivors) completed = survivors end)
	LOBBY._ban_pick.first = 1 -- deterministic: actor 1 = order[1] = host
end

-- ── Harness ────────────────────────────────────────────────────────────────
local failures = 0
local function check(cond, msg)
	if cond then print('PASS: ' .. msg) else failures = failures + 1; print('FAIL: ' .. msg) end
end

-- ── toggle contract ──────────────────────────────────────────────────────────
print()
print('-- toggle: add / remove / swap / block --')
local t = {}
check(SEL.toggle(t, 'a', 2) == 'added' and #t == 1, 'toggle adds under cap')
check(SEL.toggle(t, 'a', 2) == 'removed' and #t == 0, 'toggle removes an existing mark')
SEL.toggle(t, 'a', 1)
check(SEL.toggle(t, 'b', 1) == 'swapped' and t[1] == 'b' and #t == 1, 'cap 1: selecting another deck swaps the mark')
t = { 'a', 'b' }
check(SEL.toggle(t, 'c', 2) == 'blocked' and #t == 2, 'cap N: full selection blocks further adds')
check(SEL.toggle(t, 'c', 0) == 'blocked', 'cap 0 (not our turn / complete) blocks')

-- ── needed across step shapes ────────────────────────────────────────────────
print()
print('-- needed: ban count / pick / complete --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
check(SEL.needed(LOBBY._ban_pick) == 2, 'ban step with count=2 needs 2')
check(BP.apply_ban(LOBBY, 'host', 'b_red') == true, 'host ban 1 applies')
check(SEL.needed(LOBBY._ban_pick) == 1, 'mid-step: one ban left needs 1')
check(BP.apply_ban(LOBBY, 'host', 'b_blue') == true, 'host ban 2 applies')
check(SEL.needed(LOBBY._ban_pick) == 1, "guest's 1-ban step needs 1")
check(BP.apply_ban(LOBBY, 'guest', 'b_yellow') == true, 'guest ban applies')
check(LOBBY._ban_pick.complete and SEL.needed(LOBBY._ban_pick) == 0, 'complete draft needs 0')

-- ── prune against broadcasts ─────────────────────────────────────────────────
print()
print('-- prune: banned keys and shrunken caps drop --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
local sel = { 'b_red', 'b_blue' }
LOBBY._ban_pick.banned['b_red'] = true
sel = SEL.prune(sel, LOBBY._ban_pick)
check(#sel == 1 and sel[1] == 'b_blue', 'a mark the opponent banned is dropped')
sel = SEL.prune({ 'b_blue', 'b_green', 'b_yellow' }, LOBBY._ban_pick)
check(#sel == 2, 'marks beyond the cap are truncated')
sel = SEL.prune({ 'b_nope' }, LOBBY._ban_pick)
check(#sel == 0, 'a mark not in the pool is dropped')

-- ── confirm: correct count commits the whole selection ───────────────────────
print()
print('-- confirm: commits exactly the required selection --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
local live = SEL.list()
SEL.toggle(live, 'b_red', SEL.needed(LOBBY._ban_pick))
SEL.toggle(live, 'b_blue', SEL.needed(LOBBY._ban_pick))
G.FUNCS.mpapi_ban_pick_confirm()
check(LOBBY._ban_pick.banned['b_red'] == true and LOBBY._ban_pick.banned['b_blue'] == true,
	'confirm banned both marked decks')
check(LOBBY._ban_pick.sched_index == 2, "turn advanced to the guest's step")
check(#SEL.list() == 0, 'selection cleared after confirm')

-- ── confirm guards: wrong count and off-turn are no-ops ─────────────────────
print()
print('-- confirm guards --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
SEL.toggle(SEL.list(), 'b_red', 2)
G.FUNCS.mpapi_ban_pick_confirm()
check(LOBBY._ban_pick.banned['b_red'] ~= true, 'under-count confirm bans nothing')
check(#SEL.list() == 1, 'under-count confirm keeps the selection')
BP.apply_ban(LOBBY, 'host', 'b_yellow')
BP.apply_ban(LOBBY, 'host', 'b_green')
-- now guest's turn; host still has b_red marked
G.FUNCS.mpapi_ban_pick_confirm()
check(LOBBY._ban_pick.banned['b_red'] ~= true, 'off-turn confirm bans nothing')

-- ── confirm button enablement (per-frame check) ─────────────────────────────
print()
print('-- confirm_check: enabled only when ready --')
start_draft({ { actor = 1, action = 'ban', count = 1 } })
local e = { config = {} }
G.FUNCS.mpapi_ban_pick_confirm_check(e)
check(e.config.button == nil and e.config.colour == 'inactive', 'empty selection: button disabled')
SEL.toggle(SEL.list(), 'b_red', 1)
G.FUNCS.mpapi_ban_pick_confirm_check(e)
check(e.config.button == 'mpapi_ban_pick_confirm' and e.config.colour == 'mult', 'full selection: button live (ban colour)')

-- ── full draft with a pick step ends in on_complete ─────────────────────────
print()
print('-- pick step: confirm picks the winner --')
start_draft({ { actor = 1, action = 'ban', count = 1 }, { actor = 1, action = 'pick', count = 1 } })
SEL.toggle(SEL.list(), 'b_red', 1)
G.FUNCS.mpapi_ban_pick_confirm() -- ban b_red
check(SEL.needed(LOBBY._ban_pick) == 1, 'pick step needs exactly 1')
local e2 = { config = {} }
SEL.toggle(SEL.list(), 'b_green', 1)
G.FUNCS.mpapi_ban_pick_confirm_check(e2)
check(e2.config.colour == 'green', 'pick step: button uses pick colour')
G.FUNCS.mpapi_ban_pick_confirm() -- pick b_green
check(LOBBY._ban_pick.complete, 'pick completes the draft')
-- completion callback fires via on_state (state loops back over the wire)
BP.on_state(LOBBY, LOBBY._ban_pick)
check(completed ~= nil and #completed == 1 and completed[1] == 'b_green', 'on_complete got the picked survivor')

-- ── dice: randomize fills exactly the needed count from eligible decks ──────
print()
print('-- dice: randomize respects count, bans, and injected rng --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
LOBBY._ban_pick.banned['b_red'] = true
local first = function(_n) return 1 end -- rigged rng: always take the first eligible
local r = SEL.randomize(LOBBY._ban_pick, first)
check(#r == 2, 'randomize returns exactly the needed count')
check(r[1] ~= 'b_red' and r[2] ~= 'b_red', 'randomize never picks banned decks')
check(r[1] ~= r[2], 'randomize picks distinct decks')
check(r[1] == 'b_blue' and r[2] == 'b_yellow', 'randomize honours the injected rng')

-- ── dice button: rerolls the module selection; confirm commits it ───────────
print()
print('-- dice button: reroll then confirm commits the random selection --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
G.FUNCS.mpapi_ban_pick_random()
check(#SEL.list() == 2, 'dice press fills the selection to the needed count')
local rolled = { SEL.list()[1], SEL.list()[2] }
G.FUNCS.mpapi_ban_pick_random()
check(#SEL.list() == 2, 'second dice press re-rolls (still a full selection)')
local e3 = { config = {} }
G.FUNCS.mpapi_ban_pick_random_check(e3)
check(e3.config.button == 'mpapi_ban_pick_random' and e3.config.colour == 'blue', 'dice button live on our turn')
rolled = { SEL.list()[1], SEL.list()[2] }
G.FUNCS.mpapi_ban_pick_confirm()
check(LOBBY._ban_pick.banned[rolled[1]] == true and LOBBY._ban_pick.banned[rolled[2]] == true,
	'confirm commits the rolled selection')
G.FUNCS.mpapi_ban_pick_random_check(e3)
check(e3.config.button == nil, "dice button disabled once it's not our turn")

-- ── Summary ─────────────────────────────────────────────────────────────────
print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
