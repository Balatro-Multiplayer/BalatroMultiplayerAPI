-- Wording for the Notification kind report_action: staff acted on a player the
-- recipient reported. Shown as a chat line when online, as a login overlay
-- otherwise.
local function describe()
	return localize('k_report_action')
end

MPAPI.report_action_notice = { describe = describe }

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('report_action', describe)
end
