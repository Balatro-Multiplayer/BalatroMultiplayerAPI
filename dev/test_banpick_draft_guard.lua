--[[
  Ban-pick draft_id guard test.

  The host stamps each DRAFT with a unique draft_id; on_state drops anything
  from a dead (completed or superseded) draft_id and supersedes the old draft
  on a new draft_id. State is a full snapshot, so a duplicate simply
  re-applies harmlessly -- no per-message sequencing.

  Run from the repo root:
    luajit dev/test_banpick_draft_guard.lua
]]

-- ── Stubs ───────────────────────────────────────────────────────────────────
MPAPI = { _TEST = true, sendWarnMessage = function() end }
G = {
	FUNCS = {},
	C = { GREEN = 'green', MULT = 'mult', BLUE = 'blue', WHITE = 'white', BLACK = 'black', CLEAR = 'clear', UI = { BACKGROUND_INACTIVE = 'inactive', TEXT_LIGHT = 'light' } },
}

dofile('api/ban_pick.lua')
local BP = MPAPI.BanPick

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

-- Tuple pool: {key, stake} items, matching a server-issued pool's shape.
local POOL = {
	{ key = 'b_red', stake = 1 },
	{ key = 'b_blue', stake = 4 },
	{ key = 'b_yellow', stake = 8 },
	{ key = 'b_green', stake = 1 },
}

local function start_draft()
	BP.start(LOBBY, {
		build_pool = function()
			local copy = {}
			for i, item in ipairs(POOL) do copy[i] = item end
			return copy
		end,
		schedule = {
			{ actor = 1, action = 'ban', count = 2 },
			{ actor = 2, action = 'ban', count = 1 },
			{ actor = 1, action = 'pick', count = 1 },
		},
		state_action = 's',
		ban_action = 'b',
		on_refresh = function() end,
	}, function() end)
	LOBBY._ban_pick.first = 1 -- deterministic: actor 1 = host
end

-- ── Harness ────────────────────────────────────────────────────────────────
local failures = 0
local function check(cond, msg)
	if cond then print('PASS: ' .. msg) else failures = failures + 1; print('FAIL: ' .. msg) end
end

-- ── REGRESSION: banning one stake of a deck must not ban its twin ────────────
-- Found in MJ's in-game pass: tuple pools may repeat a deck at different stakes
-- (bot rules allow up to 3); identity keyed on the deck key alone removed BOTH
-- tiles when one was banned.
print()
print('-- regression: same deck at two stakes are independent items --')
BP.start(LOBBY, {
	build_pool = function()
		return {
			{ key = 'b_red', stake = 1 },
			{ key = 'b_red', stake = 8 },
			{ key = 'b_blue', stake = 4 },
		}
	end,
	schedule = { { actor = 1, action = 'ban', count = 1 }, { actor = 2, action = 'ban', count = 1 } },
	state_action = 's',
	ban_action = 'b',
	on_refresh = function() end,
}, function() end)
LOBBY._ban_pick.first = 1
check(BP.apply_ban(LOBBY, 'host', 'b_red@1') == true, 'ban Red@White applies')
check(LOBBY._ban_pick.banned['b_red@1'] == true, 'Red@White is banned')
check(LOBBY._ban_pick.banned['b_red@8'] == nil, 'Red@Gold is NOT banned')
check(BP.apply_ban(LOBBY, 'guest', 'b_red@8') == true, 'Red@Gold can still be banned as its own item')
local survivors_after = 0
for _, item in ipairs(LOBBY._ban_pick.pool) do
	if not LOBBY._ban_pick.banned[(type(item) == 'table' and item.stake ~= nil) and (item.key .. '@' .. item.stake) or item.key or item] then
		survivors_after = survivors_after + 1
	end
end
check(survivors_after == 1, 'exactly the untouched tuple survives')

-- ── Draft-identity guard: stale/duplicate state broadcasts, scoped per draft ─
print()
print('-- draft guard: host stamps a draft_id on the state --')
MPAPI.ActionTypes = { s = { key = 's' }, b = { key = 'b' } }
local broadcasts = {}
LOBBY.action = function(_self, _at)
	return {
		broadcast = function(_a, payload) broadcasts[#broadcasts + 1] = payload.state end,
		send = function() end,
	}
end
BP._draft_guard.reset()
start_draft()
check(type(LOBBY._ban_pick.draft_id) == 'string', 'host stamps a draft_id on the state')
check(BP.apply_ban(LOBBY, 'host', 'b_red@1') == true, 'host ban applies')
BP.broadcast_state(LOBBY)
check(#broadcasts == 2, 'both broadcasts went out')

print()
print('-- draft guard: guest start clears stale state and blocks old-draft dups --')
local GUEST = {
	is_host = false,
	player_id = 'guest',
	get_players = function(_self)
		return { { id = 'host' }, { id = 'guest' } }
	end,
}
MPAPI.get_current_lobby = function()
	return GUEST
end
local function make_state(opts)
	opts = opts or {}
	return {
		draft_id = opts.draft_id or 'hostA#1',
		pool = { 'b_red', 'b_blue' },
		banned = opts.banned or {},
		order = { 'host', 'guest' },
		first = 1,
		schedule = { { actor = 1, action = 'ban', count = 1 } },
		sched_index = 1,
		sched_remaining = 1,
		complete = opts.complete or false,
		survivors = opts.survivors,
	}
end
local guest_cfg = {
	schedule = { { actor = 1, action = 'ban', count = 1 } },
	state_action = 's',
	ban_action = 'b',
	on_refresh = function() end,
}
BP._draft_guard.reset()
local completedA, completedB = nil, nil
BP.start(GUEST, guest_cfg, function(s) completedA = s end)
BP.on_state(GUEST, make_state())
check(GUEST._ban_pick ~= nil and GUEST._ban_pick.draft_id == 'hostA#1', 'first broadcast of a draft is accepted')
local old_final = make_state({ complete = true, survivors = { 'b_red' } })
BP.on_state(GUEST, old_final)
check(completedA ~= nil and completedA[1] == 'b_red', 'old draft completes normally')
check(GUEST._ban_pick == old_final, 'old final state attached to the lobby')

BP.start(GUEST, guest_cfg, function(s) completedB = s end)
check(GUEST._ban_pick == nil, 'guest BP.start clears the previous draft state')
check(BP.is_active() == false, 'no live board while the host is still fetching the pool')
BP.on_state(GUEST, old_final)
check(GUEST._ban_pick == nil, 'late duplicate of the OLD final broadcast is ignored')
check(completedB == nil, 'old survivors do NOT complete the new draft')
BP.on_state(GUEST, make_state({ draft_id = 'hostA#2' }))
check(GUEST._ban_pick ~= nil and GUEST._ban_pick.draft_id == 'hostA#2', "the new draft's first broadcast (new draft_id) is accepted")
local legacy = { pool = { 'b_red' }, banned = {}, order = { 'host', 'guest' }, first = 1, schedule = { { actor = 1, action = 'ban', count = 1 } }, sched_index = 1, sched_remaining = 1, complete = false }
BP.on_state(GUEST, legacy)
check(GUEST._ban_pick == legacy, 'a state with NO draft_id (older host build) is accepted as before')

-- ── REGRESSION: fresh host after a long-running previous host ───────────────
-- The verifier's cross-host wedge: a guest who tracked host A through many
-- broadcasts must accept host B's brand-new draft. draft_id (dead-draft
-- marking), not sequencing, decides what is stale.
print()
print('-- regression: new host is never wedged by a dead prior-host draft --')
BP._draft_guard.reset()
local completedC = nil
BP.start(GUEST, guest_cfg, function(x) completedC = x end)
for i = 1, 8 do
	BP.on_state(GUEST, make_state({ draft_id = 'hostA#7', complete = (i == 8), survivors = { 'b_red' } }))
end
check(completedC ~= nil, 'match 1 against host A completed')
BP.start(GUEST, guest_cfg, function() end)
BP.on_state(GUEST, make_state({ draft_id = 'hostB#1' }))
check(GUEST._ban_pick ~= nil and GUEST._ban_pick.draft_id == 'hostB#1',
	"host B's first broadcast (fresh draft_id) is accepted (no cross-host floor)")
BP.on_state(GUEST, make_state({ draft_id = 'hostA#7', complete = true, survivors = { 'b_red' } }))
check(GUEST._ban_pick.draft_id == 'hostB#1', "a dup from dead host-A draft cannot displace host B's live draft")

-- ── Summary ─────────────────────────────────────────────────────────────────
print()
if failures == 0 then
	print('ALL TESTS PASSED')
	os.exit(0)
else
	print(failures .. ' TEST(S) FAILED')
	os.exit(1)
end
