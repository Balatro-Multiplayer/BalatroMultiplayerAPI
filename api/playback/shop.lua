-- Replay helpers for the shop and the blind-select screen, shared by every mod that replays a
-- recording (PvP, SPDRN) and by the generic opcodes in api/replay/generic_codes.lua.

MPAPI.playback = MPAPI.playback or {}

-- The id vanilla's BUY button gives a Booster Pack or a "Buy & Use" consumable. Vanilla's
-- check_for_buy_space refuses a pack without it, so buy_from_shop buys nothing.
MPAPI.playback.BUY_AND_USE_BUTTON_ID = 'buy_and_use'

-- Position of the Buy & Use flag in a buy, open_pack or voucher event. Logs from before the flag
-- have no such position and replay as a plain buy.
MPAPI.playback.BUY_AND_USE_ARG_INDEX = 5

-- The button id to give G.FUNCS.buy_from_shop when replaying a purchase of `card`.
function MPAPI.playback.buy_button_id(card, args)
	local is_booster = card.ability and card.ability.set == 'Booster'
	local bought_and_used = args and args[MPAPI.playback.BUY_AND_USE_ARG_INDEX] == true
	if is_booster or bought_and_used then
		return MPAPI.playback.BUY_AND_USE_BUTTON_ID
	end
	return nil
end

-- Vanilla's skip button reads the tag from the per-blind panel. G.blind_select's own first
-- tag_container is always the Small blind's.
function MPAPI.playback.current_blind_panel()
	local panel = G.blind_select_opts and G.blind_select_opts[string.lower(G.GAME.blind_on_deck or 'Small')]
	return panel or G.blind_select
end

-- Clicks "Next Round" when the game is still in the shop. A bare nil `e` crashes when an
-- installed mod reads e.config in a function that is e-free in vanilla (HandyBalatro's cash_out
-- patch), so the click always gets a real `e`.
function MPAPI.playback.leave_shop_if_needed()
	if G.STATE == G.STATES.SHOP then
		G.FUNCS.toggle_shop({ config = {} })
	end
end

MPAPI.playback.SHOP_READY_TIMEOUT_SECONDS = 10

-- A shop action can be dispatched while the shop is still being built: cash_out flips G.STATE at
-- once, but G.shop_jokers (and the other shop areas) only exist, and get their starting cards
-- (api/playback/shop_built.lua), after later queued events, and
-- the driver dispatches again as soon as the event queues are empty. Runs `fn` at once when the
-- shop is up. Otherwise pauses the driver, waits for the shop (bounded, so a replay that already
-- moved past this shop cannot hang), runs `fn` and resumes. `wait_for(predicate, callback)` is
-- the mod's own one-shot condition poll.
-- `fn` may return true to resume the driver itself later (a Booster Pack needs a further wait for
-- the pack it opens).
function MPAPI.playback.with_shop_ready(ctx, fn, wait_for)
	if MPAPI.playback.shop_is_built() then
		fn()
		return
	end
	local driver = ctx.driver
	if driver then
		driver:pause()
	end
	local timeout = MPAPI.playback.SHOP_READY_TIMEOUT_SECONDS
	local deadline = love.timer.getTime() + timeout
	wait_for(function()
		if MPAPI.playback.shop_is_built() then
			return true
		end
		if love.timer.getTime() >= deadline then
			MPAPI.playback.wait_gave_up('[replay] shop never became ready after ' .. timeout .. 's, skipping this action')
			return true
		end
		return false
	end, function()
		local resumes_itself = false
		if MPAPI.playback.shop_is_built() then
			resumes_itself = fn()
		end
		if not resumes_itself and driver then
			driver:play()
		end
	end)
end

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

-- Replays a Cash Out. The driver dispatches the next entry as soon as no blocking event is
-- queued, and a fast-forward dispatches many in one frame, so a cashout can arrive while the
-- last hand is still being evaluated (a PvP blind ends on its hands, not on its score, and its
-- evaluation has no blocking event until the next frame): clicked then, it does nothing, and the
-- round evaluation that follows waits for a click that never comes. Pauses the driver, waits for
-- the button (bounded), clicks it, waits for the shop (bounded) and resumes the driver.
-- `wait_for(predicate, callback)` is the mod's own one-shot condition poll. `before_click()` (optional)
-- runs right before the click.
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
