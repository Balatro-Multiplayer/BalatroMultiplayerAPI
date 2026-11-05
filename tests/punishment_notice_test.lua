-- Contract test: the wording of the appeal and ban end Notification kinds. Run
-- from the MPAPI repository root: luajit tests/punishment_notice_test.lua
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
MPAPI.load_mpapi_file('ui/punishment_notice.lua')

local function text(kind, params)
	return Kinds.describe(kind, params)
end

check(
	text('appeal_decided', { accepted = true, target = 'chat', result = 'lifted' })
		== 'Your appeal was accepted: your chat ban is lifted.',
	'accepted chat'
)
check(
	text('appeal_decided', { accepted = true, target = 'account', result = 'shortened' })
		== 'Your appeal was accepted: your account ban is shortened.',
	'shortened account'
)
check(
	text('appeal_decided', { accepted = true, target = 'warning', result = 'lifted' })
		== 'Your appeal was accepted: your warning is lifted.',
	'accepted warning'
)
check(
	text('appeal_decided', { accepted = true, target = 'network', result = 'lifted' })
		== 'Your appeal was accepted: your network ban is lifted.',
	'accepted network ban'
)
check(text('appeal_decided', { accepted = false, target = 'queue' }) == 'Your appeal was declined.', 'declined')
check(text('appeal_decided', { accepted = true, target = 'bogus', result = 'lifted' }) == nil, 'unknown target')
check(
	text('punishment_ended', { ban = 'queue' }) == 'Your queue ban has ended. You can join Ranked again.',
	'queue ended'
)
check(text('punishment_ended', { ban = 'chat' }) == 'Your chat ban has ended. You can chat again.', 'chat ended')
check(text('punishment_ended', { ban = 'account' }) == 'Your account ban has ended. You can play again.', 'account ended')
check(text('punishment_ended', { ban = 'warning' }) == nil, 'unknown ban')
check(
	text('punishment_ended', { ban = 'username' }) == 'Your username ban has ended.',
	'username ended'
)
check(
	text('appeal_decided', { accepted = true, target = 'username', result = 'lifted' })
		== 'Your appeal was accepted: your username ban is lifted.',
	'username appeal'
)
check(
	text('username_banned', { banName = 'Nebula Greedy' })
		== 'Your name broke the rules. Other players now see you as Nebula Greedy. You can appeal on the website.',
	'username banned'
)
check(text('username_banned', {}) == nil, 'username banned without a name')

print('punishment_notice_test: ' .. checks .. ' checks passed')
