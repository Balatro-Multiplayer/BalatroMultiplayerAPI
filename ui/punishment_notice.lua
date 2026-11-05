-- Wording for the Notification kinds appeal_decided (an appeal was accepted or
-- declined) and punishment_ended (a chat, queue or account ban ran out or was
-- lifted early). Shown as a chat line when online, as a login overlay otherwise.
local function known(key)
	local text = localize(key)
	if text == 'ERROR' or text == key then
		return nil
	end
	return text
end

local function describe_appeal(params)
	if not params.accepted then
		return known('k_appeal_declined')
	end
	local target = known('k_punishment_' .. tostring(params.target))
	local format = known(params.result == 'shortened' and 'k_appeal_shortened' or 'k_appeal_lifted')
	if not target or not format then
		return nil
	end
	return string.format(format, target)
end

local function describe_ended(params)
	return known('k_ban_ended_' .. tostring(params.ban))
end

MPAPI.punishment_notice = {
	describe_appeal = describe_appeal,
	describe_ended = describe_ended,
}

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('appeal_decided', describe_appeal)
	MPAPI.notification_kinds.register('punishment_ended', describe_ended)
end
