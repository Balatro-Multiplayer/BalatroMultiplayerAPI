-- Focus/engage tracking. `focused_mod` is whose menu is shown (nil = game main menu);
-- `engaged_mod` is whose lobby is active (nil = no lobby). Which PAGE is actually on screen
-- (mod menu vs. lobby vs. vanilla) is owned by api/page/manager.lua (MPAPI.pages.*); this file
-- decides WHEN to switch pages and keeps focused_mod/engaged_mod in sync with that choice.
MPAPI._internal.mod_registry = MPAPI._internal.mod_registry or {}
local state = MPAPI._internal.mod_registry
state.registered_mods = state.registered_mods or {}

-- Returns the current page's category ('mod_menu' | 'lobby_menu' | 'vanilla'), or nil (no
-- page shown -- i.e. before MPAPI has ever navigated, or mid-teardown into a run).
MPAPI.get_current_view = function()
	local current = MPAPI.pages.current()
	return current and current.category
end

-- Rebuilds the currently displayed mod/lobby menu in place (no animation). Mods call this
-- when lobby state that the view reads at build time changes (deck, host) and the view must
-- re-render structurally. Guarded to the main menu so it never rebuilds the menu over an
-- active run (a lobby page stays "current" in the page manager's own state during a run).
-- Also skipped when no menu is on screen: start_run tears the menu down a tick before the
-- run stage begins, and a menu rebuilt in that gap is never removed (it stays drawn behind
-- the whole run).
MPAPI.refresh_current_view = function()
	if G.STAGE ~= G.STAGES.MAIN_MENU or not G.MAIN_MENU_UI then
		return false
	end
	return MPAPI._internal.rebuild_current_menu()
end

MPAPI._internal.activate_mod = function(id)
	local mod = state.registered_mods[id]
	if not mod then
		MPAPI.sendWarnMessage('activate_mod: unknown mod ' .. tostring(id))
		return
	end

	-- Refuse to switch to a DIFFERENT mod while committed to one (in its lobby or a
	-- matchmaking queue). The mod-list buttons are already disabled for this case; this
	-- guards the programmatic path too. Re-entering the busy mod itself is allowed.
	local busy = MPAPI.get_busy_mod and MPAPI.get_busy_mod()
	if busy and busy ~= id then
		MPAPI.sendDebugMessage('activate_mod: blocked switch to ' .. tostring(id) .. ' while busy in ' .. tostring(busy))
		return
	end

	if not mod.main_menu_ui then
		-- Coming-soon mods are not yet downloadable: do nothing on activate.
		if not mod.coming_soon and mod.download_url then
			love.system.openURL(mod.download_url)
		end
		return
	end

	-- Re-entering an engaged lobby from the game main menu: skip mod menu
	-- and go straight to the lobby page.
	if id == state.engaged_mod and mod.lobby_ui then
		state.focused_mod = id
		MPAPI._internal.unlock_overlay.enable_for_mod(id)
		MPAPI.pages.show(mod.lobby_ui, { mod = mod })
		MPAPI._internal.mod_registry.update_account_button()
		return
	end

	MPAPI._internal.mod_registry.connect_to_active_mod_server(mod)
	state.focused_mod = id
	MPAPI._internal.unlock_overlay.enable_for_mod(id)
	MPAPI.pages.show(mod.main_menu_ui, { mod = mod })
	MPAPI._internal.mod_registry.update_account_button()
end

-- Focuses a mod for a run started outside its menu (a crash-rejoin from the
-- relaunched game's vanilla main menu), without showing any of its pages. The
-- unlock overlay comes with focus, and pools are built from it: without it the
-- run's tags/shop/boss rolls use the local profile's real discoveries, not the
-- everything-discovered state the live match rolled them with.
MPAPI._internal.focus_mod_for_run = function(id)
	if not state.registered_mods[id] then return end
	state.focused_mod = id
	MPAPI._internal.unlock_overlay.enable_for_mod(id)
end

-- The account panel's Back button. On a mod's own top-level page (its main menu or lobby),
-- this leaves the mod entirely, back to the game main menu. On a sub-page reached FROM within
-- a mod's menu (category outside 'mod_menu'/'lobby_menu'/'vanilla' -- e.g. a gamemode-select
-- page like SPDRN's spdrn_game_select), it instead pops back up to that mod's own main menu,
-- one level at a time, the same way pressing Back on a sub-screen normally would rather than
-- exiting the whole mod. Does NOT leave an active lobby either way.
MPAPI._internal.deactivate_mod = function()
	if not state.focused_mod then return end

	local mod = state.registered_mods[state.focused_mod]
	local current = MPAPI.pages.current()
	local on_sub_page = current and current.category ~= 'mod_menu' and current.category ~= 'lobby_menu' and current.category ~= 'vanilla'
	if on_sub_page and mod and mod.main_menu_ui then
		-- Deferred, not immediate: see MPAPI.pages.show_deferred's comment (api/page/manager.lua)
		-- -- tearing down a large sub-page and rebuilding a new one synchronously from inside
		-- this button click's own G.FUNCS handler intermittently crashed natively.
		MPAPI.pages.show_deferred(mod.main_menu_ui, { mod = mod })
		return
	end

	-- Only switch back to the default server if there is no active lobby.
	if not state.engaged_mod and mod then
		MPAPI._internal.mod_registry.connect_to_default_server(mod)
	end

	state.focused_mod = nil
	MPAPI._internal.unlock_overlay.disable()
	MPAPI.pages.show('vanilla_main_menu')
	MPAPI._internal.mod_registry.update_account_button()
end

-- A page of the lobby's mod to show when `lobby` closes, instead of the mod's main menu
-- (e.g. a tournament's screen after its match lobby closes). Applies only while the player is
-- on the lobby page or in a run: a player who has moved elsewhere in the menus stays there.
-- If the lobby closes during a run, the page is shown when the run returns to the menu. A nil
-- key clears it.
MPAPI.set_lobby_exit_page = function(lobby, key, params)
	if not lobby then return end
	lobby._exit_page = key and { key = key, params = params or {}, mod_id = lobby.mod_id } or nil
end

-- Called by lobby.lua after a lobby fires its 'connected' event.
MPAPI._internal.on_lobby_connected = function(lobby)
	state.engaged_mod = lobby.mod_id
	-- A new lobby replaces any exit page an earlier one left for after its run.
	state.pending_exit_page = nil

	-- A lobby can opt out of the lobby page (e.g. SPDRN practice drops straight into a run).
	-- Tear the whole menu down so nothing shows behind the run. Deferred -- see the long
	-- comment on MPAPI.pages.teardown_deferred in api/page/manager.lua for why this specific
	-- case (and only this one; the ordinary page swap below is not affected) cannot run here
	-- synchronously.
	if lobby.suppress_lobby_view then
		MPAPI.pages.teardown_deferred()
		MPAPI._internal.mod_registry.update_account_button()
		return
	end

	if state.focused_mod == lobby.mod_id then
		local mod = state.registered_mods[state.engaged_mod]
		if mod and mod.lobby_ui then
			-- A match formed while we were in a run (queued, then practiced): leave the
			-- run; the post-go_to_menu rebuild shows this lobby page. lobby._skip_run_exit_on_
			-- connect is a narrow, explicit opt-out for the OPPOSITE case -- a crash-relaunch
			-- rejoin (ui/rejoin_prompt.lua) that has just fast-forwarded local state to
			-- rebuild the SAME run being reconnected to, and must stay in it, not exit -- set
			-- on the lobby object by the rejoin launcher itself right after MPAPI.join_lobby
			-- returns, before this callback can fire (confirmed live: without it, rejoin's own
			-- MPAPI.join_lobby call landed here and silently exited the just-restored run
			-- back to the main menu).
			if G.STAGE == G.STAGES.RUN and not lobby._skip_run_exit_on_connect then
				MPAPI.exit_to_menu()
			elseif G.STAGE ~= G.STAGES.RUN then
				MPAPI.pages.show(mod.lobby_ui, { mod = mod, lobby = lobby })
			end
		end
	end

	MPAPI._internal.mod_registry.update_account_button()
end

-- Called by lobby.lua after a lobby fires its 'disconnected' event, with that lobby.
MPAPI._internal.on_lobby_disconnected = function(lobby)
	-- A leave answered after the player is already in another server lobby: that
	-- disconnect isn't theirs. (A local lobby, e.g. a rejoin's playback, doesn't count.)
	local current_lobby = MPAPI.get_current_lobby()
	if current_lobby and not current_lobby._local_mode then
		return
	end
	local current = MPAPI.pages.current()
	local was_in_lobby_view = current and current.category == 'lobby_menu'
	local exit_page = lobby and lobby._exit_page
	state.engaged_mod = nil

	-- If disconnecting while in a run (e.g. "Continue in Singleplayer"), clear focused_mod so
	-- the game returns to the vanilla main menu when the run ends: with focused_mod nil,
	-- rebuild_current_menu below declines to rebuild a mod page and set_main_menu_UI's rehook
	-- falls back to the base game's own menu build. A lobby with an exit page is the exception:
	-- rebuild_current_menu shows that page instead, once the run is back on the menu. Skip
	-- update_account_button() to avoid recreating the UIBox (which is in uibox mode from the
	-- main menu) over the game.
	if G.STAGE == G.STAGES.RUN then
		state.focused_mod = nil
		state.pending_exit_page = exit_page
		MPAPI._internal.unlock_overlay.disable()
		return
	end

	if was_in_lobby_view and exit_page and state.focused_mod == exit_page.mod_id then
		MPAPI.pages.show(exit_page.key, exit_page.params)
	elseif was_in_lobby_view and state.focused_mod then
		local mod = state.registered_mods[state.focused_mod]
		if mod and mod.main_menu_ui then
			MPAPI.pages.show(mod.main_menu_ui, { mod = mod })
		end
	end

	MPAPI._internal.mod_registry.update_account_button()
end

-- Rebuilds whatever page is current without animation. Used by set_main_menu_UI's rehook
-- (ui/main_menu.lua) when the game engine recreates the main menu (e.g. returning from a run).
-- Gated on focused_mod (not the page manager's own state) so the "disconnected mid-run"
-- case above -- which clears focused_mod but leaves the page manager's last-known page alone
-- -- correctly falls through to the base game's own menu build. Returns true if it handled the
-- rebuild, false if the caller should fall back to the original game menu.
MPAPI._internal.rebuild_current_menu = function()
	-- Back from a run whose lobby closed with an exit page (on_lobby_disconnected): focus its
	-- mod again and show that page, once. Dropped if the player is in a lobby again by now.
	local pending = state.pending_exit_page
	if pending then
		state.pending_exit_page = nil
		if not MPAPI.get_current_lobby() and state.registered_mods[pending.mod_id] then
			state.focused_mod = pending.mod_id
			MPAPI._internal.unlock_overlay.enable_for_mod(pending.mod_id)
			MPAPI.pages.show(pending.key, pending.params)
			return true
		end
	end
	if not state.focused_mod then
		return false
	end
	local mod = state.registered_mods[state.focused_mod]
	local current = MPAPI.pages.current()
	if not mod or not current then
		return false
	end
	MPAPI.pages.show(current.key, current.params)
	return true
end
