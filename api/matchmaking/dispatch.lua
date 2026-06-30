-- Routes an inbound matchmaking message to the right handle and drives the
-- auto-join of the matchmade lobby. Defensive init keeps this independent of the
-- load order of the matchmaking files.

MPAPI._internal.mm = MPAPI._internal.mm or {}

local function on_match_found(mm, msg)
	local handle = mm.find_handle_by_mode(msg.modId, msg.gameMode)
	if not handle then
		local available = {}
		for _, h in ipairs(mm.handles) do
			available[#available + 1] = tostring(h.mod_id) .. '/' .. tostring(h.game_mode)
		end
		MPAPI.sendWarnMessage('[mmdbg] match_found DROPPED: no handle for ' .. tostring(msg.modId) .. '/' .. tostring(msg.gameMode) .. ' | active handles=[' .. table.concat(available, ', ') .. ']')
		return
	end

	handle.match_id = msg.matchId
	-- Leave all other handles client-side (server already dequeued them)
	for _, h in ipairs(mm.handles) do
		if h ~= handle then
			h._left = true
			h:_fire(MPAPI.MatchmakingEvent.LEFT, nil)
		end
	end
	-- Keep only this handle
	local matched = handle
	mm.handles = { matched }

	matched:_fire(MPAPI.MatchmakingEvent.MATCH_FOUND, msg)

	-- Auto-join the matchmade lobby
	MPAPI.sendDebugMessage('[mmdbg] match_found OK, auto-joining lobby code=' .. tostring(msg.lobbyCode))
	local lobby = MPAPI.join_lobby(msg.modId, msg.lobbyCode)
	if lobby then
		MPAPI.sendDebugMessage('[mmdbg] join_lobby returned a lobby object, waiting for connected...')
		lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
			MPAPI.sendDebugMessage('[mmdbg] lobby connected fired, firing lobby_ready (code=' .. tostring(lobby.code) .. ' is_host=' .. tostring(lobby.is_host) .. ')')
			matched:_fire(MPAPI.MatchmakingEvent.LOBBY_READY, lobby)
		end)
		lobby:on(MPAPI.LobbyEvent.ERROR, function(err)
			MPAPI.sendWarnMessage('[mmdbg] auto-join lobby ERROR for code=' .. tostring(msg.lobbyCode) .. ': ' .. tostring(err) .. ' -- propagating to handle')
			matched:_fire(MPAPI.MatchmakingEvent.ERROR, 'lobby join failed: ' .. tostring(err))
		end)
	else
		MPAPI.sendWarnMessage('[mmdbg] join_lobby returned NIL for code=' .. tostring(msg.lobbyCode) .. ' -- lobby_ready will never fire')
		matched:_fire(MPAPI.MatchmakingEvent.ERROR, 'join_lobby returned nil for code ' .. tostring(msg.lobbyCode))
	end
end

local function on_match_reconnect(mm, msg)
	local handle = mm.find_handle_by_match_id(msg.matchId)
	if not handle then
		handle = MPAPI.matchmaking._make_handle(msg.modId, msg.gameMode)
		handle.match_id = msg.matchId
		handle._reconnected = true
	end

	local lobby = MPAPI.join_lobby(msg.modId, msg.lobbyCode)
	if lobby then
		local h = handle
		lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
			h:_fire(MPAPI.MatchmakingEvent.LOBBY_READY, lobby)
		end)
	end
end

local function on_match_resolved(mm, msg)
	local handle = mm.find_handle_by_match_id(msg.matchId)
	if handle then
		handle:_fire(MPAPI.MatchmakingEvent.MATCH_RESOLVED, msg.ratings)
		mm.remove_handle(handle)
	end
end

function MPAPI._internal.mm.dispatch(msg)
	local mm = MPAPI._internal.mm
	local msg_type = msg.type

	MPAPI.sendDebugMessage('[mmdbg] dispatch type=' .. tostring(msg_type) .. ' modId=' .. tostring(msg.modId) .. ' gameMode=' .. tostring(msg.gameMode) .. ' matchId=' .. tostring(msg.matchId) .. ' lobbyCode=' .. tostring(msg.lobbyCode))

	if msg_type == MPAPI.MatchmakingMessage.MATCH_FOUND then
		on_match_found(mm, msg)
	elseif msg_type == MPAPI.MatchmakingMessage.MATCH_RECONNECT then
		on_match_reconnect(mm, msg)
	elseif msg_type == MPAPI.MatchmakingMessage.MATCH_RESOLVED then
		on_match_resolved(mm, msg)
	end
end
