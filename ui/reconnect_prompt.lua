-- Crash-relaunch reconnect prompt: once per boot, right after the connection
-- first reaches CONNECTED, check whether the server says we're still a
-- member of a lobby (context.reconnected_lobby, computed by the connection
-- handshake itself -- see api/connection/lifecycle.lua/networking/connection.lua).
-- This is a BROADER signal than "is there an active RLOG match run in
-- progress" (MPAPI.replay.get_active_run): it's true the moment you're a
-- lobby member at all -- waiting room, mid ban-pick draft, or mid-match --
-- not just once a run has actually started. If so, show a forced choice
-- with no dismiss -- Reconnect or Abandon/Leave, nothing else -- mirroring
-- api/ban_pick.lua's build_banpick_uibox/:as_overlay({no_esc=true}) pattern,
-- the only genuinely non-dismissible overlay already in this codebase
-- (everything else -- kicked_notice_overlay, queue_guard_overlay, tos.lua --
-- documents itself as dismissible via Escape/back button).
--
-- Button label: "Abandon" for a public/ranked (matchmaking-formed) lobby,
-- "Leave" for a private one -- same underlying leave_lobby call either way
-- (lobby.service.ts's leaveLobby already forfeits any in-progress match on
-- leave regardless of lobby type, confirmed by the previous rejoin_prompt.lua
-- this file replaces -- there's no separate "abandon" endpoint), just
-- different framing for the player: leaving a private lobby is just leaving,
-- leaving a public/ranked one during a match is conceding it.
--
-- Reconnect is a two-step decision, in order:
--   1. Ask MPAPI.replay.get_active_run() whether there's an RLOG match run
--      still in progress. If so, hand off entirely to
--      MPAPI.playback.rejoin(modId, active) -- the existing mod-owned
--      fast-forward-then-live-handoff flow (unchanged by this file). This
--      MUST run before the lobby object exists: PVP._start_playback/
--      SPDRN._start_playback both refuse to bootstrap a local replay while
--      already connected to a real lobby (confirmed live -- this was the
--      actual bug in the old always-auto-create-the-lobby-object behavior;
--      see lifecycle.lua's own comment on what used to live there).
--   2. Otherwise (no active run -- still in the waiting room or mid-draft),
--      create the lobby object ourselves (MPAPI._internal.create_reconnected_lobby,
--      previously fired unconditionally and silently by lifecycle.lua) and
--      hand off to MPAPI.lobby_reconnect(modId, lobby) (api/lobby/reconnect.lua)
--      for the owning mod to rebuild its own lobby/ban-pick UI.

local _overlay = nil
local _reconnected_lobby = nil -- the context.reconnected_lobby payload itself
local _checked_this_boot = false

local function close_prompt()
	_overlay = nil
	if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
		G.FUNCS.exit_overlay_menu()
	end
	_reconnected_lobby = nil
end

local function is_public_like(lobby_data)
	-- Absent `type` defaults to private the same way api/lobby/state.lua's
	-- create_object already does for every other lobby-construction path --
	-- keeps this consistent with whatever the lobby object itself will
	-- report once actually created.
	local t = lobby_data.type or MPAPI.LobbyType.PRIVATE
	return t == MPAPI.LobbyType.PUBLIC or t == MPAPI.LobbyType.RANKED
end

local function build_reconnect_uibox(lobby_data)
	return create_UIBox_generic_options({
		no_back = true,
		no_esc = true,
		contents = {
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_reconnect_prompt_title'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.05, minh = 1 }, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_reconnect_prompt_body'), scale = 0.35, colour = G.C.UI.TEXT_INACTIVE } },
			} },
			{ n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = {
				UIBox_button({
					label = { localize('b_reconnect') },
					button = 'mpapi_reconnect_prompt_reconnect',
					minw = 3, minh = 0.8, scale = 0.4, colour = G.C.GREEN,
				}),
				{ n = G.UIT.C, config = { minw = 0.3 } },
				UIBox_button({
					label = { localize(is_public_like(lobby_data) and 'b_abandon' or 'b_leave') },
					button = 'mpapi_reconnect_prompt_leave',
					minw = 3, minh = 0.8, scale = 0.4, colour = G.C.RED,
				}),
			} },
		},
	})
end

local function show_reconnect_prompt(lobby_data)
	_reconnected_lobby = lobby_data
	_overlay = MPAPI.ui_element(function()
		return build_reconnect_uibox(lobby_data)
	end)
	_overlay:as_overlay({ no_esc = true })
end

G.FUNCS.mpapi_reconnect_prompt_reconnect = function()
	local lobby_data = _reconnected_lobby
	close_prompt()
	if not lobby_data then
		return
	end
	MPAPI.replay.get_active_run(function(err, data)
		if not err and data and data.active then
			MPAPI.playback.rejoin(data.active.modId, data.active)
			return
		end
		MPAPI._internal.create_reconnected_lobby(lobby_data)
		local lobby = MPAPI.get_current_lobby()
		if lobby then
			MPAPI.lobby_reconnect(lobby_data.modId, lobby)
		end
	end)
end

G.FUNCS.mpapi_reconnect_prompt_leave = function()
	local lobby_data = _reconnected_lobby
	close_prompt()
	if not lobby_data then
		return
	end
	local conn = MPAPI.get_connection()
	if not conn then
		return
	end
	conn.api:leave_lobby(conn.jwt_token, lobby_data.code, function(err, _data)
		if err then
			MPAPI.sendWarnMessage('[reconnect_prompt] leave_lobby failed: ' .. tostring(err.message))
		end
	end)
end

-- CONNECTED fires TWICE in a row on a successful connect
-- (networking/connection.lua's _mqtt_connect_with_credentials): once bare
-- (context = {old_state=...}), then immediately again with
-- {reconnected_lobby=...} if the auth response carried one. Guarding on
-- "have we seen A CONNECTED event yet" (rather than "have we seen the
-- reconnected_lobby-carrying one") would latch on the first, contentless
-- firing and silently skip the second -- confirmed live as a real bug during
-- this file's own testing. Only latch once we've actually SHOWN the prompt.
local function check_for_reconnected_lobby(context)
	if _checked_this_boot then
		return
	end
	if context and context.reconnected_lobby then
		_checked_this_boot = true
		show_reconnect_prompt(context.reconnected_lobby)
	end
end

MPAPI.on_connection_state_change(function(new_state, context)
	if new_state == MPAPI.ConnectionState.CONNECTED then
		check_for_reconnected_lobby(context)
	end
end)
