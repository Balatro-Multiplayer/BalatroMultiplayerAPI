-- Contract test: the wording of the staff decision Notification kinds. Run
-- from the MPAPI repository root: luajit tests/contest_result_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local dictionary = dofile('localization/en-us.lua').misc.dictionary
function localize(key)
	return dictionary[key] or 'ERROR'
end

MPAPI = { load_mpapi_file = function(path) return dofile(path) end }
local Kinds = MPAPI.load_mpapi_file('api/notification/kinds.lua')
MPAPI.load_mpapi_file('ui/contest_result_notice.lua')

local function text(kind, params)
	return Kinds.describe(kind, params)
end

check(
	text('contest_decided', { role = 'contester', outcome = 'win' }) == 'A match you contested was resolved as a win.',
	'contester win'
)
check(
	text('contest_decided', { role = 'contester', outcome = 'draw' }) == 'A match you contested was resolved as a draw.',
	'contester draw'
)
check(
	text('contest_decided', { role = 'contester', outcome = 'loss' }) == 'A match you contested was resolved as a loss.',
	'contester loss'
)
check(
	text('contest_decided', { role = 'opponent', outcome = 'loss' })
		== 'Your opponent contested a match you played. A moderator resolved it as a loss for you.',
	'opponent loss'
)
check(text('result_voided', {}) == 'A match you played was voided.', 'voided')
check(text('result_changed', { outcome = 'win' }) == 'A match you played was changed to a win.', 'changed win')
check(text('result_changed', { outcome = 'draw' }) == 'A match you played was changed to a draw.', 'changed draw')
check(text('contest_decided', { role = 'contester', outcome = 'odd' }) == nil, 'unknown outcome is left unread')
check(text('result_changed', {}) == nil, 'missing outcome is left unread')
for _, value in pairs(dictionary) do
	if type(value) == 'string' then
		check(not value:find('\226\128\148') and not value:find('\226\134\146'), 'no em-dash or arrow')
	end
end
print('contest_result_notice_test: ' .. checks .. ' checks passed')
