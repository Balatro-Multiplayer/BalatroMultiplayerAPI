-- Wording for the Notification kinds a staff decision on a match sends:
-- contest_decided (a moderator decided a contest), result_voided and
-- result_changed (staff voided a match or set its result). Shown as a chat
-- line when online, as a login overlay otherwise.
local function outcome_text(params)
	local key = 'k_staff_result_' .. tostring(params.outcome)
	local text = localize(key)
	if text == 'ERROR' or text == key then
		return nil
	end
	return text
end

local function describe_contest_decided(params)
	local outcome = outcome_text(params)
	if not outcome then
		return nil
	end
	local key = params.role == 'contester' and 'k_contest_decided_contester' or 'k_contest_decided_opponent'
	return string.format(localize(key), outcome)
end

local function describe_voided()
	return localize('k_result_voided')
end

local function describe_changed(params)
	local outcome = outcome_text(params)
	if not outcome then
		return nil
	end
	return string.format(localize('k_result_changed'), outcome)
end

MPAPI.contest_result_notice = {
	describe_contest_decided = describe_contest_decided,
	describe_voided = describe_voided,
	describe_changed = describe_changed,
}

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('contest_decided', describe_contest_decided)
	MPAPI.notification_kinds.register('result_voided', describe_voided)
	MPAPI.notification_kinds.register('result_changed', describe_changed)
end
