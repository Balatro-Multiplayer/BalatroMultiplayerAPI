-- Chat line for RESULT_LATE (110): a run the player left early has settled.
-- The match history shows the same result, so an offline player misses nothing.
local notify = MPAPI.networking.nakama_notify

local COLOUR_SYSTEM = { 1, 1, 0 }

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

if notify then
	notify.on(notify.Code.RESULT_LATE, function(content)
		MPAPI.chat.addMessage(describe(content), COLOUR_SYSTEM)
	end)
end
