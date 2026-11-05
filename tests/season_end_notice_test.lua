-- Contract test: the season_end Notification wording. One text names the
-- season, then each board with place and rating. Run from the MPAPI
-- repository root: luajit tests/season_end_notice_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

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

print(('ok   %d checks'):format(checks))
