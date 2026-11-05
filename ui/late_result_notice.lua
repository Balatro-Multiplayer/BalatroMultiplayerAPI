-- Wording for the Notification kind result_late: a run the player left early
-- has settled. Shown as a chat line when online, as a login overlay otherwise.
local function describe(content)
	local lines = { localize('k_late_result_ended') }
	if tonumber(content.place) then
		lines[#lines + 1] = localize('k_late_result_place') .. ' ' .. tostring(content.place)
	end
	local delta = type(content.rating) == 'table' and tonumber(content.rating.delta)
	if delta then
		lines[#lines + 1] = localize('k_late_result_rating') .. ': ' .. string.format('%+d', delta)
	end
	return table.concat(lines, ' ')
end

MPAPI.late_result_notice = { describe = describe }

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('result_late', describe)
end
