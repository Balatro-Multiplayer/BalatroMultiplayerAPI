-- Group casual queue: a private lobby queues for casual matchmaking as one
-- group (A-protocol.md; server: nakama/src/matchmaking/group/ and
-- lobby/group_queue.ts). The home lobby is the truth: its snapshot's
-- groupQueue and every op 112 GROUP_QUEUE say where the group is. A Nakama
-- party carries the one matchmaker ticket.
--
--   host:    party_create -> group_queue_open -> (every member in the party)
--            -> party_matchmaker_add. Re-adds the ticket on forming+requeue.
--   members: on op 112 forming, party_join; on queued, expect the ticket.
--   all:     matched (matchmaker_matched or op 112 away, whichever first):
--            match_leave the home (the seat is parked), join the public
--            lobby; once it is left, go back home by its code (home.lua).
--
-- Each player gets a matchmaking handle shaped like a solo queue's
-- (api/matchmaking/handle.lua), so a mod's lobby_ready flow is the same: the
-- host from MPAPI.matchmaking.queue_group, members through the mod's
-- Group.register(...).on_member_handle.
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI.matchmaking.group = MPAPI.matchmaking.group or {}
local Group = MPAPI.matchmaking.group

-- Seconds the host waits for every member to join the party before giving up.
Group.PARTY_TIMEOUT_SECONDS = 30

local function NL()
	return MPAPI.networking.nakama_lobby
end

local function mm()
	return MPAPI._internal.mm
end

-- This client's group queue, or nil:
-- { mod_id, mode, teams, home_code, party_id, is_host, handle, view,
--   joined, joining, party_users = { [user_id] = true }, ticket_spec,
--   want_ticket, ticket_pending, ticket, matched_id, opening }
local active = nil
-- How the last group queue ended: { reason, home_code } (shown by the UI).
Group.last_end = nil
-- mod_id -> { on_member_handle(handle, view), return_home(code) -> lobby }
local registrations = {}

-- A mod's part in the group queue. on_member_handle(handle, view) wires a
-- member's handle as the mod wires a solo queue's (lobby_ready, left, ...);
-- return_home(code) rejoins the home lobby through the mod's own join flow
-- and returns its lobby object.
function Group.register(mod_id, hooks)
	registrations[mod_id] = hooks
end

function Group._registration(mod_id)
	return registrations[mod_id]
end

----------------------------------------------------------------------
-- Planning (pure)
----------------------------------------------------------------------

-- What to do about a view of the home's group queue (a snapshot's
-- groupQueue, nil for none, or an op 112 payload) given what this client
-- knows: state = nil or { joined, ticket, matched_id, party_id }. Returns a
-- list of effects:
--   { kind = 'finish', reason }   the queue is over for us
--   { kind = 'adopt' }            a member's first word of a queue
--   { kind = 'join_party', party_id }
--   { kind = 'add_ticket' }       host: queue the party once it is whole
--   { kind = 'expect_ticket', ticket }
--   { kind = 'go_public', match_id, code }
-- Pure.
function Group.plan(state, view, me)
	local P = Group.Phase
	local fx = {}
	local phase = type(view) == 'table' and view.phase or nil
	if not phase or phase == P.IDLE then
		if state then
			fx[#fx + 1] = { kind = 'finish', reason = type(view) == 'table' and view.reason or 'gone' }
		end
		return fx
	end
	if state and state.party_id and view.partyId and state.party_id ~= view.partyId then
		fx[#fx + 1] = { kind = 'finish', reason = 'replaced' }
		state = nil
	end
	local is_host = view.hostId == me
	if not state then
		-- A queue already away (seen on a rejoin) is not ours to follow, nor
		-- is a host's queue this client didn't open (its party went with it).
		if phase == P.AWAY or is_host then
			return fx
		end
		fx[#fx + 1] = { kind = 'adopt' }
		state = {}
	end
	if phase == P.FORMING then
		if is_host then
			-- The first forming (no reason) and a refused match (requeue)
			-- want the ticket; ticket_removed was the host's own doing.
			if not view.reason or view.requeue then
				fx[#fx + 1] = { kind = 'add_ticket' }
			end
		elseif not state.joined then
			fx[#fx + 1] = { kind = 'join_party', party_id = view.partyId }
		end
	elseif phase == P.QUEUED then
		if view.ticket and state.ticket ~= view.ticket then
			fx[#fx + 1] = { kind = 'expect_ticket', ticket = view.ticket }
		end
	elseif phase == P.AWAY then
		if not state.matched_id and view.matchId then
			fx[#fx + 1] = { kind = 'go_public', match_id = view.matchId, code = view.code }
		end
	end
	return fx
end

-- Whether every member of the view is in the party, and nobody else. Pure.
function Group.party_complete(party_users, member_ids)
	local n = 0
	for _ in pairs(party_users or {}) do
		n = n + 1
	end
	if n ~= #(member_ids or {}) then
		return false
	end
	for _, id in ipairs(member_ids or {}) do
		if not party_users[id] then
			return false
		end
	end
	return true
end

----------------------------------------------------------------------
-- State reads
----------------------------------------------------------------------

-- True while this client's group is forming or queued (not yet matched).
function Group.is_active()
	return active ~= nil and not active.matched_id
end

-- A copy of this client's group queue state for the UI, or nil.
function Group.state()
	if not active then
		return nil
	end
	local view = active.view or {}
	return {
		phase = active.matched_id and Group.Phase.AWAY or view.phase or Group.Phase.FORMING,
		mod_id = active.mod_id,
		mode = active.mode,
		teams = active.teams,
		home_code = active.home_code,
		is_host = active.is_host,
		member_ids = view.memberIds,
		matched_id = active.matched_id,
	}
end

----------------------------------------------------------------------
-- Effects
----------------------------------------------------------------------

local function notice(text)
	if MPAPI.show_notice then
		MPAPI.show_notice('k_group_queue_failed_title', text)
	end
end

local function finish(reason)
	local a = active
	if not a then
		return
	end
	active = nil
	Group.last_end = { reason = reason, home_code = a.home_code }
	if a.ticket then
		NL().expect_ticket(a.ticket, nil)
	end
	local h = a.handle
	if h and not h._left and not a.matched_id then
		h._left = true
		mm().remove_handle(h)
		h:_fire(MPAPI.MatchmakingEvent.LEFT, nil)
	end
	MPAPI.sendDebugMessage('[group] queue over: ' .. tostring(reason))
end
Group._finish = finish

-- Gives up on the group queue (any member may): the server ends it for
-- everyone. cb(err) once it answered.
function Group.cancel(cb)
	cb = cb or function() end
	NL().rpc('group_queue_cancel', {}, function(err, data)
		if err then
			MPAPI.sendWarnMessage('[group] cancel failed: ' .. tostring(err))
			cb(err)
			return
		end
		if data and data.refused then
			cb(Group.refusal_text(data.refused))
			return
		end
		finish('cancelled')
		cb(nil)
	end)
end

-- The handle a group queue hands its mod. leave() cancels the group queue
-- while it is forming or queued; once matched it only drops the handle.
local function make_handle(mod_id, game_mode)
	local handle = MPAPI.matchmaking._make_handle(mod_id, game_mode)
	handle._group = true
	function handle:leave()
		if self._left then
			return
		end
		if self.match_id or not (active and active.handle == self) then
			self._left = true
			mm().remove_handle(self)
			self:_fire(MPAPI.MatchmakingEvent.LEFT, nil)
			return
		end
		Group.cancel()
	end
	mm().handles[#mm().handles + 1] = handle
	return handle
end

local go_public

local function on_matched(match_id)
	-- No match id: the server refused the match; op 112 forming (requeue)
	-- or idle follows.
	if match_id then
		go_public(match_id)
	end
end

local function try_add_ticket()
	local a = active
	if not a or not a.is_host or not a.want_ticket or a.ticket_pending or not a.party_id then
		return
	end
	local view = a.view
	if not view or view.phase ~= Group.Phase.FORMING then
		return
	end
	if not Group.party_complete(a.party_users, view.memberIds) then
		return
	end
	a.want_ticket = false
	a.ticket_pending = true
	NL().party_queue(a.party_id, a.ticket_spec, function(err, ticket)
		if active ~= a then
			return
		end
		a.ticket_pending = false
		if err then
			MPAPI.sendWarnMessage('[group] party ticket refused: ' .. tostring(err))
			notice(tostring(err))
			Group.cancel()
			return
		end
		a.ticket = ticket
		NL().expect_ticket(ticket, on_matched)
	end)
end

local function want_ticket()
	local a = active
	a.want_ticket = true
	try_add_ticket()
	-- Members who never make it into the party (a failed join, a client
	-- that isn't running the group queue) would hold the lobby forever.
	NL().after(Group.PARTY_TIMEOUT_SECONDS, function()
		if active == a and a.want_ticket and not a.ticket then
			MPAPI.sendWarnMessage('[group] not every member joined the party; cancelling')
			notice(localize('k_group_party_timeout'))
			Group.cancel()
		end
	end)
end

local function join_party(party_id)
	local a = active
	if a.joining or a.joined then
		return
	end
	a.joining = true
	NL().party_join(party_id, function(err)
		if active ~= a then
			return
		end
		a.joining = false
		if err then
			MPAPI.sendWarnMessage('[group] party join failed: ' .. tostring(err))
			notice(tostring(err))
			Group.cancel()
			return
		end
		a.joined = true
	end)
end

local function adopt(view)
	local handle = make_handle(view.modId, view.mode)
	active = {
		mod_id = view.modId,
		mode = view.mode,
		teams = view.teams and true or false,
		home_code = view.homeCode,
		party_id = view.partyId,
		is_host = false,
		handle = handle,
		view = view,
	}
	local reg = registrations[view.modId]
	if reg and reg.on_member_handle then
		local ok, err = pcall(reg.on_member_handle, handle, view)
		if not ok then
			MPAPI.sendWarnMessage('[group] on_member_handle failed: ' .. tostring(err))
		end
	end
end

-- Matched: out of the home socket-wise (the server parks the seat), into
-- the public lobby. Once from whichever of matchmaker_matched / op 112 away
-- comes first.
go_public = function(match_id)
	local a = active
	if not a or a.matched_id then
		return
	end
	a.matched_id = match_id
	if a.ticket then
		NL().expect_ticket(a.ticket, nil)
	end
	local L = MPAPI._internal.lobby
	local home = L.current
	NL().step_out()
	if home and home.code == a.home_code then
		-- Quietly: no DISCONNECTED, so the mod's lobby teardown (which drops
		-- its matchmaking handle) doesn't run on the way to the public lobby.
		home._group_stepped_out = true
		L.cleanup(home)
	end
	Group.Home.remember(a.mod_id, a.home_code, match_id)
	local handle = a.handle
	handle:on(MPAPI.MatchmakingEvent.LOBBY_READY, function(lobby)
		lobby:on(MPAPI.LobbyEvent.DISCONNECTED, function()
			Group.Home.on_public_left(match_id)
		end)
		lobby:on(MPAPI.LobbyEvent.GAME_ENDED, function()
			Group.Home.on_public_game_ended(lobby, match_id)
		end)
	end)
	handle:on(MPAPI.MatchmakingEvent.ERROR, function()
		if handle.match_id == match_id then
			Group.Home.on_public_left(match_id)
		end
	end)
	mm().on_nakama_matched(handle, match_id)
end
Group._go_public = go_public

local function run(fx, view)
	for _, e in ipairs(fx) do
		if e.kind == 'finish' then
			finish(e.reason)
		elseif e.kind == 'adopt' then
			adopt(view)
		elseif e.kind == 'join_party' and active then
			join_party(e.party_id)
		elseif e.kind == 'add_ticket' and active then
			want_ticket()
		elseif e.kind == 'expect_ticket' and active then
			active.ticket = e.ticket
			NL().expect_ticket(e.ticket, on_matched)
		elseif e.kind == 'go_public' then
			go_public(e.match_id)
		end
	end
end

-- The home lobby's word on its group queue: an op 112 payload, or a
-- snapshot's groupQueue (nil for none). From api/lobby/nakama.lua.
function Group._on_view(lobby, view)
	if not lobby or lobby.type == 'public' or lobby.type == 'ranked' then
		return
	end
	if active and active.home_code and lobby.code and lobby.code ~= active.home_code then
		return
	end
	-- The host's own open is still in flight: a snapshot from before it
	-- says nothing about it.
	if active and active.opening and type(view) ~= 'table' then
		return
	end
	if type(view) == 'table' and view.phase == Group.Phase.IDLE and view.reason then
		Group.last_end = { reason = view.reason, home_code = lobby.code }
	end
	local before = active and active.view
	local was = before and before.phase
	if active and type(view) == 'table' and view.phase == Group.Phase.FORMING and was == Group.Phase.QUEUED then
		-- The ticket is gone (taken back, or spent on a refused match).
		if active.ticket then
			NL().expect_ticket(active.ticket, nil)
		end
		active.ticket = nil
	end
	local state = active and {
		joined = active.joined or active.is_host,
		ticket = active.ticket,
		matched_id = active.matched_id,
		party_id = active.party_id,
	}
	local fx = Group.plan(state, view, lobby.player_id)
	if active and type(view) == 'table' and view.phase ~= Group.Phase.IDLE then
		active.view = view
		active.teams = view.teams and true or false
	end
	run(fx, view)
	if not active or type(view) ~= 'table' then
		return
	end
	if view.phase == Group.Phase.QUEUED and was ~= Group.Phase.QUEUED then
		if mm().queue_timer then
			mm().queue_timer.start()
		end
		active.handle:_fire(MPAPI.MatchmakingEvent.QUEUED, nil)
	end
	-- A presence event may have come in before this view named the members.
	try_add_ticket()
end

-- The home lobby went away under us (left, kicked, lost) while the group
-- was forming or queued: the server ended the queue, but we can't hear it.
function Group._on_lobby_gone(lobby)
	if active and not active.matched_id and lobby and lobby.code == active.home_code and not lobby._group_stepped_out then
		finish('left_lobby')
	end
end

-- Party events from the socket (networking/nakama_lobby.lua).
local function on_party_event(kind, message)
	local a = active
	if kind == 'socket_lost' then
		-- The party (and its ticket) went with the socket; the home's
		-- snapshot on the rejoin says how the queue ended.
		if a then
			a.joined = false
			a.party_users = {}
		end
		return
	end
	if not a or not a.party_id then
		return
	end
	if kind == 'party' then
		local party = message.party
		if party and party.party_id == a.party_id then
			a.party_users = {}
			for _, p in ipairs(party.presences or {}) do
				if p.user_id then
					a.party_users[p.user_id] = true
				end
			end
			if not a.is_host then
				a.joined = true
			end
		end
	elseif kind == 'presence' then
		local ev = message.party_presence_event
		if ev and ev.party_id == a.party_id then
			a.party_users = a.party_users or {}
			for _, p in ipairs(ev.joins or {}) do
				if p.user_id then
					a.party_users[p.user_id] = true
				end
			end
			for _, p in ipairs(ev.leaves or {}) do
				if p.user_id then
					a.party_users[p.user_id] = nil
				end
			end
		end
	end
	try_add_ticket()
end

local function set_listener()
	local nl = NL()
	if nl and nl.set_party_listener then
		nl.set_party_listener(on_party_event)
	end
end

----------------------------------------------------------------------
-- Host entry point
----------------------------------------------------------------------

-- Queues the current private lobby as one group (host only). opts as
-- MPAPI.matchmaking.queue's (mod_id, game_mode, min_players, max_players),
-- plus teams = true for a Teams mode. Returns the handle, or nil and a
-- refusal { code } (Group.refusal_text says it to the player). A server
-- refusal arrives later as the handle's ERROR (and a notice).
function Group.queue(opts)
	local R = Group.Refusal
	local lobby = MPAPI.get_current_lobby()
	local conn = MPAPI.get_connection()
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		return nil, { code = R.NOT_IN_LOBBY }
	end
	if active then
		return nil, { code = R.ALREADY_QUEUED }
	end
	if opts.ranked or opts.lobby_type == MPAPI.LobbyType.RANKED then
		return nil, { code = R.RANKED }
	end
	local facts = Group.facts_from_lobby(lobby)
	local refusal = Group.eligibility(facts, nil)
	if refusal then
		return nil, refusal
	end
	local size = #facts.member_ids
	local spec, too_small = Group.party_ticket(opts, size, opts.teams and true or false)
	if not spec then
		return nil, too_small
	end
	set_listener()

	local handle = make_handle(opts.mod_id, opts.game_mode)
	local a = {
		mod_id = opts.mod_id,
		mode = spec.strings.mode,
		teams = opts.teams and true or false,
		home_code = lobby.code,
		is_host = true,
		handle = handle,
		party_users = {},
		ticket_spec = spec,
		opening = true,
	}
	active = a

	local function refused(text, err_kind)
		if active == a then
			active = nil
		end
		if a.party_id then
			NL().party_leave(a.party_id)
		end
		handle._left = true
		mm().remove_handle(handle)
		handle:_fire(MPAPI.MatchmakingEvent.ERROR, MPAPI.make_error(err_kind or MPAPI.ErrorKind.SERVER, text))
		notice(text)
	end

	NL().party_create(Group.MAX_SIZE, function(err, party)
		if active ~= a then
			return
		end
		if err then
			refused(tostring(err))
			return
		end
		a.party_id = party.party_id
		a.party_users[(party.self and party.self.user_id) or lobby.player_id] = true
		for _, p in ipairs(party.presences or {}) do
			if p.user_id then
				a.party_users[p.user_id] = true
			end
		end
		NL().rpc('group_queue_open', { partyId = a.party_id, mode = a.mode, teams = a.teams }, function(rpc_err, data)
			if active ~= a then
				return
			end
			a.opening = false
			if rpc_err then
				refused(tostring(rpc_err))
				return
			end
			if data and data.refused then
				refused(Group.refusal_text(data.refused), MPAPI.ErrorKind.VALIDATION)
				return
			end
			-- op 112 usually beats this reply; a reply after it is stale.
			local view = data and data.groupQueue
			if type(view) == 'table' and not a.view then
				local current = MPAPI.get_current_lobby()
				if current then
					current.group_queue = view
				end
				Group._on_view(current or lobby, view)
			end
		end)
	end)
	return handle
end

-- Replaces the dead pre-Nakama stub: queue the whole private lobby (host).
MPAPI.matchmaking.queue_group = function(opts)
	return Group.queue(opts)
end

set_listener()
