-- Chat line for RESULT_RANKED (111): a ranked match has settled. Every player it
-- rated gets one, including a player who left early. The match history shows the
-- same result, so an offline player misses nothing.
local notify = MPAPI.networking.nakama_notify

local COLOUR_SYSTEM = { 1, 1, 0 }

local function describe(content)
	local lines = { localize('k_ranked_result_ended') }
	local place = tonumber(content.place)
	if place then
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

if notify then
	notify.on(notify.Code.RESULT_RANKED, function(content)
		MPAPI.chat.addMessage(describe(content), COLOUR_SYSTEM)
	end)
end
