-- Group casual queue: getting back to the home lobby after the public match.
-- The home kept our seat (parked while away); the protocol (A-protocol.md,
-- "Coming back") is: leave the public lobby properly (lobby_leave / LEAVE,
-- else the rejoin is refused "Already in lobby"), then join the home by its
-- code. Each mod rejoins through its own join flow (Group.register's
-- return_home) so its lobby UI comes up as for any join by code.
--
--   public game over -> once back at the main menu, leave the public lobby
--   public lobby left -> once at the main menu, rejoin the home
--
-- A player still in a run (continued solo) or past the retry window keeps a
-- pending return: the mod's main menu shows "Return to lobby XXXX"
-- (Group.pending_return / Group.return_home).
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI.matchmaking.group = MPAPI.matchmaking.group or {}
local Group = MPAPI.matchmaking.group
Group.Home = Group.Home or {}
local Home = Group.Home

-- How long to wait for the main menu before leaving the return to the
-- player's own button, and how long a pending return is offered at all (the
-- server's away cap is 90 minutes; the seat grace after it ~2).
Home.AUTO_RETURN_SECONDS = 15
Home.PENDING_SECONDS = 95 * 60
Home.POLL_SECONDS = 0.5

-- { mod_id, home_code, match_id, since, left_public, returning } or nil.
local pending = nil

local function NL()
	return MPAPI.networking.nakama_lobby
end

local function now()
	return love and love.timer and love.timer.getTime() or os.clock()
end

-- At the main menu once it is built: go_to_menu sets the stage at once but
-- builds the menu (set_main_menu_UI, which rebuilds whatever page is current)
-- seconds later, so a lobby page shown before that was replaced by the page
-- current before it (seen live with SPDRN: its main menu on screen while in
-- the home lobby).
local function at_main_menu()
	return G and G.STAGES and G.STAGE == G.STAGES.MAIN_MENU and G.STATE == G.STATES.MENU and G.MAIN_MENU_UI ~= nil
end

-- The return this client still owes its home lobby for `mod_id` (nil for
-- any mod): { home_code, mod_id }, or nil.
function Group.pending_return(mod_id)
	if not pending then
		return nil
	end
	if now() - pending.since > Home.PENDING_SECONDS then
		pending = nil
		return nil
	end
	if mod_id and pending.mod_id ~= mod_id then
		return nil
	end
	if pending.returning or not pending.left_public then
		return nil
	end
	return { home_code = pending.home_code, mod_id = pending.mod_id }
end

function Home.forget()
	pending = nil
end

-- Matched: from here the home code is what we go back to.
function Home.remember(mod_id, home_code, match_id)
	pending = { mod_id = mod_id, home_code = home_code, match_id = match_id, since = now() }
end

-- Rejoins the home lobby now. Returns the lobby object, or nil.
function Group.return_home()
	local p = pending
	if not p or p.returning then
		return nil
	end
	local current = MPAPI.get_current_lobby()
	if current then
		if current.code == p.home_code then
			pending = nil
			return current
		end
		MPAPI.sendWarnMessage('[group] still in lobby ' .. tostring(current.code) .. '; not returning home yet')
		return nil
	end
	p.returning = true
	MPAPI.sendDebugMessage('[group] returning to lobby ' .. tostring(p.home_code))
	local reg = Group._registration(p.mod_id)
	-- Leaving the public game lands on the game's own main menu with no mod
	-- focused, where a joined lobby has no page to show: focus the mod first,
	-- as a player opening its menu would, so CONNECTED shows the lobby page.
	local registry = MPAPI._internal.mod_registry
	if at_main_menu() and registry and registry.focused_mod ~= p.mod_id and MPAPI._internal.activate_mod then
		pcall(MPAPI._internal.activate_mod, p.mod_id)
	end
	local lobby
	local ok, err = pcall(function()
		if reg and reg.return_home then
			lobby = reg.return_home(p.home_code)
		else
			lobby = MPAPI.join_lobby(p.mod_id, p.home_code)
		end
	end)
	if not ok then
		MPAPI.sendWarnMessage('[group] return home failed: ' .. tostring(err))
	end
	if not lobby then
		p.returning = false
		return nil
	end
	local connected = false
	lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
		connected = true
		if pending == p then
			pending = nil
		end
		if MPAPI.refresh_current_view then
			MPAPI.refresh_current_view()
		end
	end)
	lobby:on(MPAPI.LobbyEvent.ERROR, function(e)
		if pending == p and not connected then
			-- The seat is gone (grace ran out, the lobby closed): nothing to
			-- go back to.
			pending = nil
			if MPAPI.show_notice then
				MPAPI.show_notice('k_group_return_failed_title', tostring(e and e.message or e))
			end
		end
	end)
	return lobby
end

-- Polls (on NL's timers) until `ready()` or `seconds` pass; then `go()`.
local function when_ready(p, seconds, ready, go)
	local deadline = now() + seconds
	local function tick()
		if pending ~= p then
			return
		end
		if ready() then
			go()
			return
		end
		if now() < deadline then
			NL().after(Home.POLL_SECONDS, tick)
		end
	end
	tick()
end

-- The automatic return may only take a player who is idle at the game's own
-- main menu or already in the group's mod. One who opened another mod's menu
-- meanwhile is left there; the group's mod offers "Return to lobby" when they
-- come back to it (Group.pending_return).
function Home.may_auto_return(mod_id)
	if not at_main_menu() or MPAPI.get_current_lobby() then
		return false
	end
	local focused = MPAPI.get_focused_mod()
	return focused == nil or focused == mod_id
end

-- The public lobby is behind us (left, closed, or its join failed).
function Home.on_public_left(match_id)
	local p = pending
	if not p or p.match_id ~= match_id or p.left_public then
		return
	end
	p.left_public = true
	-- The public match was the group queue's last act.
	Group._finish('away_over')
	when_ready(p, Home.AUTO_RETURN_SECONDS, function()
		return Home.may_auto_return(p.mod_id)
	end, function()
		Group.return_home()
	end)
end

-- The public lobby's (first) game is over: once the player is back at the
-- main menu (its lobby view), leave the public lobby; its DISCONNECTED takes
-- us home.
function Home.on_public_game_ended(lobby, match_id)
	local p = pending
	if not p or p.match_id ~= match_id then
		return
	end
	when_ready(p, Home.PENDING_SECONDS, function()
		return at_main_menu() or lobby._destroyed
	end, function()
		if not lobby._destroyed and MPAPI.get_current_lobby() == lobby then
			MPAPI.sendDebugMessage('[group] public game over; leaving lobby ' .. tostring(lobby.code))
			lobby:leave()
		end
	end)
end
