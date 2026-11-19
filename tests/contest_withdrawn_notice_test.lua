-- Contract test: the wording for the Notification kind contest_withdrawn is
-- registered, and it names the result (win, draw or loss) when it is known.
-- Run from the MPAPI repository root: luajit tests/contest_withdrawn_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local strings = dofile('localization/en-us.lua').misc.dictionary
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
check(describe({ runId = 'r', outcome = 'win' }) == 'Your opponent withdrew their contest. You won.', 'a win says won')
check(describe({ runId = 'r', outcome = 'draw' }) == 'Your opponent withdrew their contest. It was a draw.', 'a draw says draw')
check(describe({ runId = 'r', outcome = 'loss' }) == 'Your opponent withdrew their contest. You lost.', 'a loss says lost')
check(describe({}) == 'Your opponent withdrew their contest.', 'an unknown outcome gives only the first line')
check(describe(nil) == 'Your opponent withdrew their contest.', 'no content does not error')

print(('ok   %d checks'):format(checks))
