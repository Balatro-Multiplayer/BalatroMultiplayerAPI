-- Wording for the Notification kind result_ranked: a ranked match has settled.
-- Every player it rated gets one, including a player who left early. Shown as a
-- chat line when online, as a login overlay otherwise.
local function describe(content)
	local lines = { localize('k_ranked_result_ended') }
	local place = tonumber(content.place)
	if place and (tonumber(content.players) or 2) > 2 then
		lines[#lines + 1] = localize('k_late_result_place') .. ' ' .. tostring(place) .. '.'
	elseif place then
		local key = (place == 1 and content.tied and 'k_ranked_result_drew')
			or (place == 1 and 'k_ranked_result_won')
			or 'k_ranked_result_lost'
		lines[#lines + 1] = localize(key)
	end
	-- No rating while the player is still in their placement games; the game that
	-- ends them shows the first rating, as a placement, not a change.
	local rating = type(content.rating) == 'table' and content.rating or nil
	if rating and rating.justPlaced and tonumber(rating.newRating) then
		lines[#lines + 1] = localize('k_ranked_result_placement') .. ': ' .. tostring(math.floor(rating.newRating + 0.5))
	elseif rating and not rating.isPlacement and tonumber(rating.delta) then
		lines[#lines + 1] = localize('k_late_result_rating') .. ': ' .. string.format('%+d', rating.delta)
	end
	return table.concat(lines, ' ')
end

MPAPI.ranked_result_notice = { describe = describe }

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('result_ranked', describe)
end
