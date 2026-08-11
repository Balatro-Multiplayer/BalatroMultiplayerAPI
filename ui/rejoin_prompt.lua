-- Crash-relaunch rejoin/abandon prompt: once per boot, right after the
-- connection first reaches CONNECTED, ask the server whether this player
-- has a match still in progress (MPAPI.replay.get_active_run --
-- api/replay/api.lua, backed by the server's live in-memory RLOG buffer, see
-- replay-log.service.ts's findActiveRunForPlayer). If so, show a forced
-- choice with no dismiss -- Rejoin or Abandon, nothing else -- mirroring
-- api/ban_pick.lua's build_banpick_uibox/:as_overlay({no_esc=true}) pattern,
-- the only genuinely non-dismissible overlay already in this codebase
-- (everything else -- kicked_notice_overlay, queue_guard_overlay, tos.lua --
-- documents itself as dismissible via Escape/back button).
--
-- Rejoin dispatches to whichever mod registered a rejoin launcher for the
-- active run's modId (MPAPI.playback.rejoin, api/playback/registry.lua) --
-- MPAPI itself has no idea how to fast-forward a seeded local run for any
-- given mod's gamemode, only the mod that recorded it does (same reasoning
-- as MPAPI.playback.launch's own doc comment).
--
-- Abandon calls the ordinary lobby-leave endpoint directly (the same one
-- G.FUNCS.exit_overlay_menu-triggered "Leave Lobby" buttons already use) --
-- an explicit leave is already an immediate forfeit server-side
-- (lobby.service.ts's leaveLobby -> forfeitMatchForLeave), no separate
-- "abandon" endpoint needed. The disconnected player is still tracked as a
-- lobby member server-side (pending their 2-minute grace period) until this
-- fires, so the call succeeds the same way it would for a still-connected
-- player choosing to leave.

local _overlay = nil
local _active = nil -- {runId, lobbyCode, modId}
local _checked_this_boot = false

local function close_prompt()
	_overlay = nil
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
	_active = nil
end

local function build_rejoin_uibox()
	return create_UIBox_generic_options({
		no_back = true,
		no_esc = true,
		contents = {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_rejoin_prompt_title'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.05, minh = 1 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_rejoin_prompt_body'), scale = 0.35, colour = G.C.UI.TEXT_INACTIVE } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = {
				UIBox_button({
					label = { localize('b_rejoin') },
					button = 'mpapi_rejoin_prompt_rejoin',
					minw = 3, minh = 0.8, scale = 0.4, colour = G.C.GREEN,
				}),
				{ n = G.UIT.C, config = { minw = 0.3 } },
				UIBox_button({
					label = { localize('b_abandon') },
					button = 'mpapi_rejoin_prompt_abandon',
					minw = 3, minh = 0.8, scale = 0.4, colour = G.C.RED,
				}),
			} },
		},
	})
end

local function show_rejoin_prompt(active)
	_active = active
	_overlay = MPAPI.ui_element(build_rejoin_uibox)
	_overlay:as_overlay({ no_esc = true })
end

G.FUNCS.mpapi_rejoin_prompt_rejoin = function()
	local active = _active
	close_prompt()
	if active then
		MPAPI.playback.rejoin(active.modId, active)
	end
end

G.FUNCS.mpapi_rejoin_prompt_abandon = function()
	local active = _active
	close_prompt()
	if not active then
		return
	end
	local conn = MPAPI.get_connection()
	if not conn then
		return
	end
	conn.api:leave_lobby(conn.jwt_token, active.lobbyCode, function(err, _data)
		if err then
			MPAPI.sendWarnMessage('[rejoin_prompt] abandon (leave_lobby) failed: ' .. tostring(err.message))
		end
	end)
end

local function check_for_active_run()
	if _checked_this_boot then
		return
	end
	_checked_this_boot = true
	MPAPI.replay.get_active_run(function(err, data)
		if err or not data or not data.active then
			return
		end
		show_rejoin_prompt(data.active)
	end)
end

MPAPI.on_connection_state_change(function(new_state, _context)
	if new_state == MPAPI.ConnectionState.CONNECTED then
		check_for_active_run()
	end
end)
