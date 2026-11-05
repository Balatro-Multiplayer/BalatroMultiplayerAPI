-- Wording for the Notification kind season_end: a season ended. One text lists
-- each board the player has a ranked entry on, with place and rating. Shown as
-- a chat line when online, as a login overlay otherwise.
local function ordinal(n)
	local last_two = n % 100
	local suffix = 'th'
	if last_two < 11 or last_two > 13 then
		local last = n % 10
		suffix = (last == 1 and 'st') or (last == 2 and 'nd') or (last == 3 and 'rd') or 'th'
	end
	return tostring(n) .. suffix
end

local function board_name(board)
	return localize('k_season_end_ranked') .. ' ' .. tostring(board.name)
end

local function describe(content)
	local season = tonumber(content.season)
	local name = (type(content.name) == 'string' and content.name ~= '' and content.name)
		or (season and (localize('k_season_end_season') .. ' ' .. season))
		or localize('k_season_end_season')
	local lines = { name .. ' ' .. localize('k_season_end_ended') }
	local boards = {}
	for _, board in ipairs(type(content.boards) == 'table' and content.boards or {}) do
		local place, rating = tonumber(board.place), tonumber(board.rating)
		if place and rating and type(board.name) == 'string' and board.name ~= '' then
			boards[#boards + 1] = board_name(board)
				.. ': '
				.. ordinal(math.floor(place))
				.. ', '
				.. localize('k_season_end_rating')
				.. ' '
				.. tostring(math.floor(rating + 0.5))
				.. '.'
		end
	end
	for _, line in ipairs(boards) do
		lines[#lines + 1] = line
	end
	return table.concat(lines, ' ')
end

MPAPI.season_end_notice = { describe = describe, ordinal = ordinal }

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('season_end', describe)
end
