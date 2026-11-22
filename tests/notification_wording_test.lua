-- Contract test: the wording of each Notification kind (ui/*_notice.lua).
local T = dofile('tests/support.lua')
local check = T.check

-- The staff decision, appeal, ban end and report_action kinds, through the real kinds table.
T.part(function()
	local dictionary = dofile('localization/en-us.lua').misc.dictionary
	function localize(key)
		return dictionary[key] or 'ERROR'
	end

	MPAPI = { load_mpapi_file = function(path) return dofile(path) end }
	local Kinds = MPAPI.load_mpapi_file('api/notification/kinds.lua')
	MPAPI.load_mpapi_file('ui/contest_result_notice.lua')
	MPAPI.load_mpapi_file('ui/punishment_notice.lua')
	MPAPI.load_mpapi_file('ui/report_action_notice.lua')

	local function text(kind, params)
		return Kinds.describe(kind, params)
	end

	-- Staff decisions on a match.
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

	-- Appeals and ban ends.
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
	check(text('punishment_ended', { ban = 'username' }) == 'Your username ban has ended.', 'username ended')
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

	-- A report someone acted on.
	check(
		text('report_action', {}) == 'Action has been taken against a player you reported, thank you for reporting.',
		'report action wording'
	)

	for _, value in pairs(dictionary) do
		if type(value) == 'string' then
			check(not value:find('\226\128\148') and not value:find('\226\134\146'), 'no em-dash or arrow')
		end
	end
end)

-- contest_withdrawn is registered, and it names the result (win, draw or loss) when it is known.
T.part(function()
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
end)

-- season_end: one text names the season, then each board with place and rating.
T.part(function()
	local strings = {
		k_season_end_season = 'Season',
		k_season_end_ended = 'has ended.',
		k_season_end_ranked = 'Ranked',
		k_season_end_rating = 'rating',
	}
	function localize(key)
		return strings[key] or key
	end

	local registered = {}
	MPAPI = {
		notification_kinds = {
			register = function(kind, fn)
				registered[kind] = fn
			end,
		},
	}
	dofile('ui/season_end_notice.lua')
	local describe = registered.season_end
	check(describe, 'the season_end kind is registered')

	check(
		describe({ season = 4, name = 'Season 4', boards = { { name = 'PvP', place = 37, rating = 1520 } } })
			== 'Season 4 has ended. Ranked PvP: 37th, rating 1520.',
		'one board reads as the spec example'
	)
	local two = describe({
		season = 4,
		name = 'Season 4',
		boards = {
			{ name = 'PvP Vanilla', place = 1, rating = 1700.4 },
			{ name = 'Speedrun Gold Stake Single', place = 22, rating = 1210 },
		},
	})
	check(two:find('Ranked PvP Vanilla: 1st, rating 1700.', 1, true), 'first board: ' .. two)
	check(two:find('Ranked Speedrun Gold Stake Single: 22nd, rating 1210.', 1, true), 'second board: ' .. two)
	local ord = MPAPI.season_end_notice.ordinal
	check(ord(11) == '11th' and ord(12) == '12th' and ord(13) == '13th', 'teens end in th')
	check(ord(21) == '21st' and ord(2) == '2nd' and ord(103) == '103rd' and ord(10) == '10th', 'ordinals')
	check(describe({ season = 4 }) == 'Season 4 has ended.', 'no boards still reads')
end)

T.done('notification_wording_test')
