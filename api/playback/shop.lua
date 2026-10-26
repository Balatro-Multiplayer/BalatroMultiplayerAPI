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

-- G.shop_jokers exists one frame before its starting cards do (api/playback/shop_built.lua).
local function shop_is_ready()
	return MPAPI.playback.shop_is_built()
end

-- A shop action can be dispatched while the shop is still being built: cash_out flips G.STATE at
-- once, but G.shop_jokers (and the other shop areas) only exist after a later queued event, and
-- the driver dispatches again as soon as the event queues are empty. Runs `fn` at once when the
-- shop is up. Otherwise pauses the driver, waits for the shop (bounded, so a replay that already
-- moved past this shop cannot hang), runs `fn` and resumes. `wait_for(predicate, callback)` is
-- the mod's own one-shot condition poll.
-- `fn` may return true to resume the driver itself later (a Booster Pack needs a further wait for
-- the pack it opens).
function MPAPI.playback.with_shop_ready(ctx, fn, wait_for)
	if shop_is_ready() then
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
		if shop_is_ready() then
			return true
		end
		if love.timer.getTime() >= deadline then
			MPAPI.sendWarnMessage('[replay] shop never became ready after ' .. timeout .. 's, skipping this action')
			return true
		end
		return false
	end, function()
		local resumes_itself = false
		if shop_is_ready() then
			resumes_itself = fn()
		end
		if not resumes_itself and driver then
			driver:play()
		end
	end)
end
