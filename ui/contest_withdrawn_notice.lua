-- Wording for the Notification kind contest_withdrawn: the other player
-- withdrew their Contest, so the match counts as their forfeit. content.outcome
-- is this player's result in the match: win, draw or loss.
local function describe(content)
	local outcome = type(content) == 'table' and content.outcome or nil
	local result_key = outcome == 'win' and 'k_contest_withdrawn_won'
		or outcome == 'draw' and 'k_contest_withdrawn_drew'
		or outcome == 'loss' and 'k_contest_withdrawn_lost'
		or nil
	local text = localize('k_contest_withdrawn')
	if result_key then
		text = text .. ' ' .. localize(result_key)
	end
	return text
end

MPAPI.contest_withdrawn_notice = { describe = describe }

if MPAPI.notification_kinds then
	MPAPI.notification_kinds.register('contest_withdrawn', describe)
end
