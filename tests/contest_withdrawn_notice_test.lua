-- Contract test: the wording for the Notification kind contest_withdrawn is
-- registered, and it names the result (win, draw or loss) when it is known.
-- Run from the MPAPI repository root: luajit tests/contest_withdrawn_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local strings = {
	k_contest_withdrawn = 'Withdrawn.',
	k_contest_withdrawn_won = 'Won.',
	k_contest_withdrawn_drew = 'Drew.',
	k_contest_withdrawn_lost = 'Lost.',
}
function localize(key)
	return strings[key] or ('?' .. key)
end

local registered = {}
MPAPI = {
	notification_kinds = {
		register = function(kind, fn)
			registered[kind] = fn
		end,
	},
}
dofile('ui/contest_withdrawn_notice.lua')

check(registered.contest_withdrawn ~= nil, 'the kind is registered')
local describe = registered.contest_withdrawn
check(describe({ runId = 'r', outcome = 'win' }) == 'Withdrawn. Won.', 'a win says won')
check(describe({ runId = 'r', outcome = 'draw' }) == 'Withdrawn. Drew.', 'a draw says draw')
check(describe({ runId = 'r', outcome = 'loss' }) == 'Withdrawn. Lost.', 'a loss says lost')
check(describe({}) == 'Withdrawn.', 'an unknown outcome gives only the first line')
check(describe(nil) == 'Withdrawn.', 'no content does not error')

print(('ok   %d checks'):format(checks))
