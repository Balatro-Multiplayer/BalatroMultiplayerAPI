-- Contract test: the wording of the report_action Notification kind. Run from
-- the MPAPI repository root: luajit tests/report_action_notice_test.lua
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
MPAPI.load_mpapi_file('ui/report_action_notice.lua')

check(
	Kinds.describe('report_action', {}) == 'Action has been taken against a player you reported, thank you for reporting.',
	'report action wording'
)
local text = dictionary.k_report_action
check(not text:find('\226\128\148') and not text:find('\226\134\146'), 'no em-dash or arrow')
print('report_action_notice_test: ' .. checks .. ' checks passed')
