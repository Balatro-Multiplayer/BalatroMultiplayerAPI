-- Replay of a Cash Out, shared by every mod that replays a recording (PvP, SPDRN).

MPAPI.playback = MPAPI.playback or {}

MPAPI.playback.CASHOUT_WAIT_SECONDS = 10

-- The Cash Out button is its own UIBox, built some time after the round_eval screen. Calling
-- cash_out before it exists removes G.round_eval first, and the button is then built with no
-- major to follow: it leaks off screen.
function MPAPI.playback.find_cash_out_button()
	for _, box in pairs(G.I.UIBOX) do
		local found
		local function walk(node)
			if found or not node then return end
			if node.config and node.config.button == 'cash_out' then found = node return end
			for _, child in ipairs(node.children or {}) do walk(child) end
		end
		walk(box.UIRoot)
		if found then return found end
	end
end

-- True when the wait for a Cash Out can end: the button exists, the round was already cashed out
-- (no round_eval and the state is past ROUND_EVAL), or time ran out. A state before ROUND_EVAL
-- also has no round_eval, so those states keep waiting: the last hand of a round has been
-- scored, but the game needs more frames to evaluate the round.
function MPAPI.playback.cashout_wait_over(button_exists, round_eval_built, state, timed_out)
	if button_exists or timed_out then return true end
	local S = G.STATES
	local before_round_eval = state == S.SELECTING_HAND or state == S.HAND_PLAYED or state == S.DRAW_TO_HAND or state == S.NEW_ROUND
	return not round_eval_built and state ~= S.ROUND_EVAL and not before_round_eval
end

-- Replays a Cash Out. A fast-forward can dispatch it while the last hand is still being
-- evaluated (a PvP blind ends on its hands, and that evaluation has no blocking event until the
-- next frame), and a click then does nothing: the round evaluation waits for a click that never
-- comes. So the driver pauses until the button exists. `wait_for(predicate, callback)` is the
-- mod's own one-shot condition poll; `before_click()` (optional) runs right before the click.
function MPAPI.playback.cash_out_when_ready(ctx, wait_for, before_click)
	local driver = ctx.driver
	if driver then driver:pause() end
	local timeout = MPAPI.playback.CASHOUT_WAIT_SECONDS
	local button_deadline = love.timer.getTime() + timeout
	wait_for(function()
		return MPAPI.playback.cashout_wait_over(MPAPI.playback.find_cash_out_button() ~= nil, G.round_eval ~= nil, G.STATE, love.timer.getTime() >= button_deadline)
	end, function()
		local button = MPAPI.playback.find_cash_out_button()
		if not button then
			MPAPI.playback.wait_gave_up('[replay] cashout: no Cash Out button after ' .. timeout .. 's, clicking anyway')
		end
		if before_click then before_click() end
		G.FUNCS.cash_out(button or { config = {} })
		local deadline = love.timer.getTime() + timeout
		wait_for(function()
			if G.STATE == G.STATES.ROUND_EVAL then
				if love.timer.getTime() >= deadline then
					MPAPI.playback.wait_gave_up('[replay] cashout: still in ROUND_EVAL after ' .. timeout .. 's, resuming anyway')
					return true
				end
				return false
			end
			if G.STATE == G.STATES.SHOP then
				if MPAPI.playback.shop_is_built() then return true end
				if love.timer.getTime() >= deadline then
					MPAPI.playback.wait_gave_up('[replay] cashout: shop never became ready after ' .. timeout .. 's, resuming anyway')
					return true
				end
				return false
			end
			return true
		end, function()
			if driver then driver:play() end
		end)
	end)
end
