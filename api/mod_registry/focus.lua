-- Focus/engage tracking and view transitions. `focused_mod` is whose menu is shown
-- (nil = game main menu); `engaged_mod` is whose lobby is active (nil = no lobby);
-- `current_view` is a MPAPI.ViewMode value or nil (no mod view shown).
MPAPI._internal.mod_registry = MPAPI._internal.mod_registry or {}
local state = MPAPI._internal.mod_registry
state.registered_mods = state.registered_mods or {}

-- Returns a MPAPI.ViewMode value, or nil (game main menu).
MPAPI.get_current_view = function()
	return state.current_view
end

-- Rebuilds the currently displayed mod/lobby menu in place (no animation). Mods call
-- this when lobby state that the view reads at build time changes (deck, host) and the
-- view must re-render structurally. Guarded to the main menu so it never rebuilds the
-- menu over an active run (current_view stays LOBBY_MENU during a run).
MPAPI.refresh_current_view = function()
	if G.STAGE ~= G.STAGES.MAIN_MENU then
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
	-- and go straight to the lobby view.
	if id == state.engaged_mod and mod.lobby_ui then
		state.focused_mod = id
		state.current_view = MPAPI.ViewMode.LOBBY_MENU
		state.pending_cleanup = nil
		MPAPI._internal.mod_registry.replace_main_menu(mod.lobby_ui)
		MPAPI._internal.mod_registry.update_account_button()
		return
	end

	MPAPI._internal.mod_registry.connect_to_active_mod_server(mod)
	state.focused_mod = id
	state.current_view = MPAPI.ViewMode.MOD_MENU
	MPAPI._internal.mod_registry.replace_main_menu(mod.main_menu_ui)
	MPAPI._internal.mod_registry.update_account_button()
end

-- Returns to the game main menu. Does NOT leave an active lobby.
MPAPI._internal.deactivate_mod = function()
	if not state.focused_mod then return end

	local mod = state.registered_mods[state.focused_mod]
	-- Only switch back to the default server if there is no active lobby.
	if not state.engaged_mod and mod then
		MPAPI._internal.mod_registry.connect_to_default_server(mod)
	end

	state.focused_mod = nil
	state.current_view = nil
	state.pending_cleanup = nil
	MPAPI._internal.mod_registry.restore_main_menu()
	MPAPI._internal.mod_registry.update_account_button()
end

-- Called by lobby.lua after a lobby fires its 'connected' event.
MPAPI._internal.on_lobby_connected = function(lobby)
	state.engaged_mod = lobby.mod_id

	-- A lobby can opt out of the lobby-menu view (e.g. SPDRN practice drops straight into a run).
	-- Tear the whole menu down so nothing shows behind the run; current_view is cleared so the
	-- post-run rebuild does not restore a lobby view that was never shown.
	if lobby.suppress_lobby_view then
		MPAPI.teardown_menu()
		state.current_view = nil
		MPAPI._internal.mod_registry.update_account_button()
		return
	end

	if state.focused_mod == lobby.mod_id then
		local mod = state.registered_mods[state.engaged_mod]
		if mod and mod.lobby_ui then
			state.current_view = MPAPI.ViewMode.LOBBY_MENU
			-- A match formed while we were in a run (queued, then practiced): leave the run; the
			-- post-go_to_menu rebuild shows this lobby view.
			if G.STAGE == G.STAGES.RUN then
				MPAPI.exit_to_menu()
			else
				MPAPI._internal.mod_registry.replace_main_menu(mod.lobby_ui)
			end
		end
	end

	MPAPI._internal.mod_registry.update_account_button()
end

-- Called by lobby.lua after a lobby fires its 'disconnected' event.
MPAPI._internal.on_lobby_disconnected = function()
	local was_in_lobby_view = state.current_view == MPAPI.ViewMode.LOBBY_MENU
	state.engaged_mod = nil
	state.pending_cleanup = nil

	-- If disconnecting while in a run (e.g. "Continue in Singleplayer"),
	-- clear focused state so the game returns to the vanilla main menu
	-- when the run ends. Skip update_account_button() to avoid recreating
	-- the UIBox (which is in uibox mode from the main menu) over the game.
	if G.STAGE == G.STAGES.RUN then
		state.focused_mod = nil
		state.current_view = nil
		return
	end

	if was_in_lobby_view and state.focused_mod then
		local mod = state.registered_mods[state.focused_mod]
		if mod and mod.main_menu_ui then
			state.current_view = MPAPI.ViewMode.MOD_MENU
			MPAPI._internal.mod_registry.replace_main_menu(mod.main_menu_ui)
		end
	end

	MPAPI._internal.mod_registry.update_account_button()
end

-- Rebuilds the current view without animation. Used by set_main_menu_UI
-- when the game engine recreates the main menu (e.g. returning from a run).
-- Returns true if it handled the rebuild, false if the caller should fall
-- back to the original game menu.
MPAPI._internal.rebuild_current_menu = function()
	state.pending_cleanup = nil
	if state.focused_mod and state.current_view == MPAPI.ViewMode.LOBBY_MENU then
		local mod = state.registered_mods[state.focused_mod]
		if mod and mod.lobby_ui then
			MPAPI._internal.mod_registry.replace_main_menu(mod.lobby_ui)
			return true
		end
	end
	if state.focused_mod and state.current_view == MPAPI.ViewMode.MOD_MENU then
		local mod = state.registered_mods[state.focused_mod]
		if mod and mod.main_menu_ui then
			MPAPI._internal.mod_registry.replace_main_menu(mod.main_menu_ui)
			return true
		end
	end
	return false
end
