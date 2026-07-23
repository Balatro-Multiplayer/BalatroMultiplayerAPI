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
local warns = {}
MPAPI = {
	_TEST = true,
	sendWarnMessage = function(msg) warns[#warns + 1] = msg end,
}
localize = function(k) return k end
G = {
	FUNCS = {},
	C = { GREEN = 'green', RED = 'red', MULT = 'mult', BLUE = 'blue', WHITE = 'white', BLACK = 'black', CLEAR = 'clear', UI = { BACKGROUND_INACTIVE = 'inactive', TEXT_LIGHT = 'light' } },
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
check(e.config.button == 'mpapi_ban_pick_confirm' and e.config.colour == 'green', 'full selection: button live and green (the confirm signal)')

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

-- ── random button: BLIND commit -- nothing revealed until confirmed ─────────
print()
print('-- random: arms blind, reveals nothing, confirm rolls and commits --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
local e3 = { config = {} }
G.FUNCS.mpapi_ban_pick_random_check(e3)
check(e3.config.button == 'mpapi_ban_pick_random' and e3.config.colour == 'blue', 'random button live on our turn')
G.FUNCS.mpapi_ban_pick_random()
check(SEL.armed() == true, 'random press arms blind-random')
check(#SEL.list() == 0, 'arming reveals NOTHING (no marks, no picks exist yet)')
G.FUNCS.mpapi_ban_pick_random_check(e3)
check(e3.config.colour == 'red', 'armed random button goes red (Cancel Random)')
check(SEL.ui().random_text == 'k_banpick_cancel_random', 'random label flips to Cancel Random')
check(SEL.ui().confirm_text == 'k_banpick_confirm_random', 'confirm label reads Confirm Random')
check(SEL.ui().count_text == '?/2', 'counter hides the picks (?/N)')
local e4 = { config = {} }
G.FUNCS.mpapi_ban_pick_confirm_check(e4)
check(e4.config.button == 'mpapi_ban_pick_confirm', 'confirm goes live while armed (no marks needed)')
G.FUNCS.mpapi_ban_pick_random()
check(SEL.armed() == false, 'second random press disarms back to manual')
G.FUNCS.mpapi_ban_pick_random()
check(SEL.armed() == true, 're-armed')
G.FUNCS.mpapi_ban_pick_confirm()
check(SEL.armed() == false, 'confirm consumed the armed state')
local banned_count = 0
for _ in pairs(LOBBY._ban_pick.banned) do banned_count = banned_count + 1 end
check(banned_count == 2, 'confirm rolled and committed exactly the needed count')
check(LOBBY._ban_pick.sched_index == 2, "turn advanced to the guest's step")

print()
print('-- random: manual marks clear on arm; tile-click disarms --')
start_draft({ { actor = 1, action = 'ban', count = 2 }, { actor = 2, action = 'ban', count = 1 } })
SEL.toggle(SEL.list(), 'b_red', 2)
G.FUNCS.mpapi_ban_pick_random()
check(SEL.armed() and #SEL.list() == 0, 'arming clears manual marks')

-- ── random: a SHORT roll commits NOTHING ─────────────────────────────────────
-- Eligible survivors < the step's remaining count: committing the partial batch
-- would exhaust the pool mid-step and wedge the draft with no legal action left.
print()
print('-- random: short roll (eligible < needed) commits nothing --')
start_draft({ { actor = 1, action = 'ban', count = 3 }, { actor = 2, action = 'ban', count = 1 } })
LOBBY._ban_pick.banned['b_red'] = true
LOBBY._ban_pick.banned['b_blue'] = true
warns = {}
G.FUNCS.mpapi_ban_pick_random()
check(SEL.armed() == true, 'armed over a too-small pool (arming itself is allowed)')
G.FUNCS.mpapi_ban_pick_confirm()
local short_banned = 0
for _ in pairs(LOBBY._ban_pick.banned) do short_banned = short_banned + 1 end
check(short_banned == 2, 'confirm committed NOTHING beyond the pre-existing bans')
check(LOBBY._ban_pick.sched_index == 1 and LOBBY._ban_pick.sched_remaining == 3, 'the step is untouched, not wedged mid-way')
check(LOBBY._ban_pick.complete ~= true, 'draft not completed')
check(SEL.armed() == false, 'blind-random disarmed')
check(#warns == 1 and warns[1]:find('nothing committed', 1, true) ~= nil, 'short roll warns instead of committing')
check(SEL.ui().count_text == '0/3', 'counter re-synced after the refused roll')

-- ── guest confirm: UI syncs immediately, before the host rebroadcast ─────────
-- On a guest, request_ban only sends the wire message: without the explicit
-- sync the tiles keep their Selected tags and the counter reads a full N/N
-- until the host's state broadcast lands.
print()
print('-- guest confirm: clears tags and counter immediately --')
local sent = {}
local GUEST = {
	is_host = false,
	player_id = 'guest',
	get_players = function(_self)
		return { { id = 'host' }, { id = 'guest' } }
	end,
	action = function(_self, _at)
		return {
			send = function(_a, to, payload) sent[#sent + 1] = { to = to, key = payload.item_key } end,
			broadcast = function() end,
		}
	end,
}
MPAPI.get_current_lobby = function()
	return GUEST
end
MPAPI.ActionTypes = { test_state = { key = 'test_state' }, test_ban = { key = 'test_ban' } }
BP._draft_guard.reset()
BP.start(GUEST, {
	schedule = { { actor = 1, action = 'ban', count = 2 } },
	state_action = 'test_state',
	ban_action = 'test_ban',
	on_refresh = function() end,
}, function() end)
-- Host's broadcast: guest's turn (first = 2 makes actor 1 resolve to order[2]).
BP.on_state(GUEST, {
	pool = { unpack(POOL) },
	banned = {},
	order = { 'host', 'guest' },
	first = 2,
	schedule = { { actor = 1, action = 'ban', count = 2 } },
	sched_index = 1,
	sched_remaining = 2,
	complete = false,
})
local function fake_card(id)
	return {
		mp_item_id = id,
		highlighted = true,
		children = { mp_sel_tag = { remove = function(self) self.removed = true end } },
		T = { w = 1 },
	}
end
local c1, c2 = fake_card('b_red'), fake_card('b_blue')
SEL.set_areas({ { cards = { c1, c2 } } })
SEL.toggle(SEL.list(), 'b_red', 2)
SEL.toggle(SEL.list(), 'b_blue', 2)
G.FUNCS.mpapi_ban_pick_confirm()
check(#sent == 2 and sent[1].to == 'host' and sent[2].to == 'host', 'guest confirm sent both bans to the host')
check(sent[1].key == 'b_red' and sent[2].key == 'b_blue', 'wire carries the marked ids')
check(#SEL.list() == 0, 'selection cleared')
check(c1.highlighted == false and c2.highlighted == false, 'tiles lowered immediately')
check(c1.children.mp_sel_tag == nil and c2.children.mp_sel_tag == nil, 'Selected tags removed immediately')
check(SEL.ui().count_text == '0/2', 'counter reads 0/N, not a stale full N/N')
SEL.set_areas({})
MPAPI.get_current_lobby = function()
	return LOBBY
end
MPAPI.ActionTypes = {}

-- ── stake column: two-phase gather/build is orphan-free on failure ──────────
-- localize{type='descriptions'} constructs live DynaText/UIBox objects the
-- moment it runs; a failed build must release every one of them (they would
-- otherwise draw unparented at the screen origin).
print()
print('-- stake column: gather/build happy path --')
local SC = BP._stake_column
G.UIT = { R = 'R', C = 'C', T = 'T', B = 'B', O = 'O' }
G.P_CENTER_POOLS = { Stake = { { key = 'stake1' }, { key = 'stake2' }, { key = 'stake3' } } }
get_stake_col = function(i) return 'col' .. i end
local made_objects = {}
local desc_calls = 0
local desc_fail_on = nil
local plain_localize = localize
localize = function(arg)
	if type(arg) ~= 'table' then
		return arg
	end
	if arg.type == 'name_text' then
		return 'NAME:' .. arg.key
	end
	-- descriptions: two lines, each carrying a live object (the {E:} analogue),
	-- appended into the caller's nodes table exactly like the real localize.
	desc_calls = desc_calls + 1
	if desc_calls == desc_fail_on then
		error('loc boom')
	end
	for line = 1, 2 do
		local obj = { remove = function(self) self.removed = true end }
		made_objects[#made_objects + 1] = obj
		arg.nodes[line] = { { n = 'O', config = { object = obj } } }
	end
end
local gathered = { descs = {}, line_sets = {} }
SC.gather({ key = 'b_x', stake = 3 }, gathered)
check(gathered.ready == true, 'gather completes')
check(gathered.name == 'NAME:stake3' and gathered.name_colour == 'col3', 'name + colour gathered as plain data')
check(#gathered.descs == 2, 'own stake + one previous stake gathered')
check(#gathered.descs[2].lines == 1, "previous stake's boilerplate line dropped")
check(made_objects[4].removed == true, "the dropped line's live object was released at drop time")
local right = SC.build(gathered)
check(#right == 4, 'build: name row, own chip row, Also applied label, previous chip row')
check(right[1].nodes[1].config.text == 'NAME:stake3', 'name row first')
check(right[3].nodes[1].config.text == 'k_also_applied', 'label sits after the own-stake row')
check(right[2].nodes[1].nodes[1].config.colour == 'col3' and right[4].nodes[1].nodes[1].config.colour == 'col2',
	'chip swatches carry the gathered stake colours')

print()
print('-- stake column: mid-gather failure releases every constructed object --')
made_objects = {}
desc_calls = 0
desc_fail_on = 2
local gathered2 = { descs = {}, line_sets = {} }
local ok2 = pcall(SC.gather, { key = 'b_x', stake = 3 }, gathered2)
check(ok2 == false, 'second descriptions call throws')
check(gathered2.ready ~= true, 'gather not marked ready')
check(#made_objects == 2, 'first call had constructed two live objects')
SC.release(gathered2)
check(made_objects[1].removed == true and made_objects[2].removed == true,
	'release removed every already-constructed object (orphan-free)')

print()
print('-- stake column: unknown stake index gathers nothing, no error --')
desc_fail_on = nil
local gathered3 = { descs = {}, line_sets = {} }
local ok3 = pcall(SC.gather, { key = 'b_x', stake = 99 }, gathered3)
check(ok3 == true and gathered3.ready ~= true and #gathered3.descs == 0, 'missing stake center: silent empty column')
localize = plain_localize

-- ── Summary ─────────────────────────────────────────────────────────────────
print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
