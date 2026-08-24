-- The page transition engine: the single place that swaps G.MAIN_MENU_UI content, runs a
-- page's enter/cleanup lifecycle, and defers unsafe transitions to the next clean Game:update
-- tick. Replaces api/mod_registry/view.lua's replace_main_menu/restore_main_menu/teardown_menu
-- and the transition logic in api/mod_registry/focus.lua; those files now call MPAPI.pages.*
-- instead of touching G.MAIN_MENU_UI themselves.
MPAPI._internal.page_manager = MPAPI._internal.page_manager or {}
local pm = MPAPI._internal.page_manager
pm.current_key = pm.current_key or nil
pm.current_params = pm.current_params or nil
pm.current_instance = pm.current_instance or nil
pm.previous = pm.previous or nil -- { key, params }, for MPAPI.pages.back()
pm.pending_cleanup = pm.pending_cleanup or nil
pm.pending_transition = pm.pending_transition or nil

-- Capture the game's original set_main_menu_UI here, at api/ load time, BEFORE ui/ rehooks it
-- (ui/main_menu.lua). The vanilla page (api/page/vanilla.lua) calls this to reconstruct the
-- base game's own main menu. Guarded so re-execution (defensive load order) never overwrites
-- the original with an already-hooked version.
if pm.original_set_main_menu_UI == nil then
	pm.original_set_main_menu_UI = set_main_menu_UI
end

MPAPI.pages = MPAPI.pages or {}

local function _remove_menu_ui()
	if G.MAIN_MENU_UI then
		G.MAIN_MENU_UI:remove()
	end
	if G.PROFILE_BUTTON then
		G.PROFILE_BUTTON:remove()
		G.PROFILE_BUTTON = nil
	end
end

-- Builds and shows a page instance. `render` (if the page defines one) fully overrides this --
-- used by the vanilla page, whose real menu-build procedure also has side effects (G.PROFILE_
-- BUTTON) beyond one UIBox. Every other page just returns a UIT definition from `build`.
local function _build_and_show(def, instance)
	if def.render then
		instance:render()
		return
	end
	G.MAIN_MENU_UI = UIBox({
		definition = instance:build(),
		config = { align = 'bmi', offset = { x = 0, y = 10 }, major = G.ROOM_ATTACH, bond = 'Weak' },
	})
	G.MAIN_MENU_UI.alignment.offset.y = 0
	G.MAIN_MENU_UI:align_to_major()
end

-- Changes the active page immediately. cleanup(instance, uibox) on the OUTGOING page may
-- return (delay, on_enter) to animate the transition (e.g. SPDRN's slide between its main menu
-- and lobby -- see BalatroMultiplayerSpeed/core.lua's page registrations).
MPAPI.pages.show = function(key, params)
	local def = MPAPI.Pages[key]
	if not def then
		MPAPI.sendWarnMessage('MPAPI.pages.show: unknown page \'' .. tostring(key) .. '\'')
		return
	end

	-- Gated on G.MAIN_MENU_UI (not just on having a tracked instance): cleanup(instance, uibox)
	-- unconditionally dereferences uibox to animate it, so it must only run when there is
	-- actually a live UIBox to animate away from. When the base game's own run-start machinery
	-- has already destroyed G.MAIN_MENU_UI without going through MPAPI.pages.teardown() (e.g.
	-- starting a run straight from the lobby page, no suppress_lobby_view involved) and the
	-- post-run set_main_menu_UI rehook calls MPAPI.pages.show to restore it, there is nothing
	-- left to animate -- this guard is what makes that rebuild silent instead of crashing on a
	-- nil uibox.
	local delay, on_enter_override = 0, nil
	if pm.pending_cleanup and G.MAIN_MENU_UI then
		delay, on_enter_override = pm.pending_cleanup(pm.current_instance, G.MAIN_MENU_UI)
		delay = delay or 0
	end

	local instance = def:new_instance(params)
	pm.pending_cleanup = def.cleanup

	local function finish()
		_remove_menu_ui()
		_build_and_show(def, instance)
		if pm.current_key then
			pm.previous = { key = pm.current_key, params = pm.current_params }
		end
		pm.current_key = key
		pm.current_params = params
		pm.current_instance = instance
		if instance.on_enter then
			instance:on_enter()
		end
		if on_enter_override then
			on_enter_override(G.MAIN_MENU_UI)
		end
	end

	if delay > 0 then
		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = delay,
			func = function()
				finish()
				return true
			end,
		}))
	else
		finish()
	end
end

MPAPI.pages.current = function()
	if not pm.current_key then
		return nil
	end
	local def = MPAPI.Pages[pm.current_key]
	return {
		key = pm.current_key,
		category = def and def.category,
		params = pm.current_params,
		instance = pm.current_instance,
	}
end

MPAPI.pages.current_key = function()
	return pm.current_key
end

-- Re-shows whatever page was active before the current one.
MPAPI.pages.back = function()
	if not pm.previous then
		return
	end
	local p = pm.previous
	MPAPI.pages.show(p.key, p.params)
end

-- Tears the current page down to nothing (no page takes its place -- used going into a run).
-- Deliberately does NOT invoke a page's cleanup(instance, uibox): that hook exists to animate
-- into a NEXT page, which doesn't apply here, and calling it against a UIBox mid-removal risks
-- erroring against elements already gone. Mirrors the old MPAPI.teardown_menu exactly.
MPAPI.pages.teardown = function()
	pm.pending_cleanup = nil
	pm.current_key = nil
	pm.current_params = nil
	pm.current_instance = nil

	for _, key in ipairs({ 'MAIN_MENU_UI', 'PROFILE_BUTTON', 'title_top', 'SPLASH_LOGO' }) do
		if G[key] then
			pcall(function() G[key]:remove() end)
			G[key] = nil
		end
	end
	-- account_button is a separate 'uibox'-mode ui_element (ui/main_menu.lua), weakly bonded
	-- to G.ROOM_ATTACH rather than tracked as one of the keys above, so it isn't guaranteed to
	-- be torn down by the base game's own remove_all(G.STAGE_OBJECTS[...]) when a run starts.
	-- Remove its UIBox directly; the ui_element wrapper safely no-ops a stale reference on its
	-- next as_uibox()/update() call (api/ui_element.lua).
	if MPAPI.account_button then
		local uibox = MPAPI.account_button:get_uibox()
		if uibox then
			pcall(function() uibox:remove() end)
		end
	end
	-- The version display is an anonymous top-right ('tri') UIBox among the menu's stage objects.
	local menu_objects = G.STAGE_OBJECTS and G.STAGES and G.STAGE_OBJECTS[G.STAGES.MAIN_MENU]
	for i = menu_objects and #menu_objects or 0, 1, -1 do
		local o = menu_objects[i]
		if o and o.config and o.config.align == 'tri' then
			pcall(function() o:remove() end)
		end
	end
end

-- Compat alias: MPAPI.teardown_menu was the old name (view.lua), kept because
-- api/mod_registry/view.lua's MPAPI.cleanup/exit_to_menu still call it.
MPAPI.teardown_menu = MPAPI.pages.teardown

-- Queues a full teardown for the next clean Game:update tick instead of running it here. A
-- lobby can opt out of showing a lobby page at all (e.g. SPDRN practice drops straight into a
-- run -- see lobby.suppress_lobby_view in api/mod_registry/focus.lua): when that happens mid-
-- lobby-connect, the whole menu must go away with nothing behind the run.
--
-- Why deferred: the caller (on_lobby_connected) runs from inside an Event's func, mid-way
-- through EventManager:update()'s own event-queue loop for this frame. Tearing the menu down
-- synchronously from there is unsafe: MPAPI.pages.teardown()'s title_top:remove() nils
-- title_top.cards *before* deregistering it from G.I.CARDAREA a few lines later (see
-- cardarea.lua's CardArea:remove), leaving a window, still within this same frame, where the
-- base engine's own per-frame G.I.CARDAREA move loop (game.lua, later in Game:update than
-- EventManager:update()) could visit title_top with cards already nil and crash on cardarea.
-- lua's `ipairs(self.cards)`. Reliably reproduced going through the real practice deck-select
-- UI (SPDRN practice's overlay -> confirm -> begin_run); never hit calling SPDRN._start_
-- practice directly, which skips the overlay entirely. Flushing after the frame's own
-- Game:update (and therefore after that frame's EventManager:update() and CardArea move loop)
-- have both already returned avoids the window -- the same shape as SPDRN's own run_start.lua
-- request_run_transition/_check_pending_run_transition pattern for the identical class of hazard.
MPAPI.pages.teardown_deferred = function()
	pm.pending_transition = { teardown = true }
end

local function _flush_pending_transition()
	if not pm.pending_transition then
		return
	end
	local t = pm.pending_transition
	pm.pending_transition = nil
	if t.teardown then
		MPAPI.pages.teardown()
		-- Skip rebuilding the account button's UIBox over an active run -- same hazard
		-- on_lobby_disconnected guards against (api/mod_registry/focus.lua): the button is in
		-- uibox mode from the main menu, so update_account_button() would recreate/redraw it
		-- on top of the game. This path fires for any flow that drops straight into a run
		-- without the normal lobby-menu screens (SPDRN/PvP practice, replay playback), which is
		-- exactly when G.STAGE is already G.STAGES.RUN by the time this runs.
		if G.STAGE == G.STAGES.RUN then
			return
		end
		if MPAPI._internal.mod_registry and MPAPI._internal.mod_registry.update_account_button then
			MPAPI._internal.mod_registry.update_account_button()
		end
	end
end

if not MPAPI._page_transition_hooked then
	MPAPI._page_transition_hooked = true
	local _ref = Game.update
	function Game:update(dt)
		_ref(self, dt)
		pcall(_flush_pending_transition)
	end
end
