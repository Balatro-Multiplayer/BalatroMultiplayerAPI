-- Drives a matched handle into its lobby, and ends handles the server
-- cancelled. Defensive init keeps this independent of the
-- load order of the matchmaking files.

MPAPI._internal.mm = MPAPI._internal.mm or {}

-- A Nakama matchmaker group was found for `handle`: the lobby already exists
-- on the server, so join it by match id.
function MPAPI._internal.mm.on_nakama_matched(handle, match_id)
	local mm = MPAPI._internal.mm
	if handle._left then
		return
	end
	-- No match: the server refused the group (e.g. another player was banned
	-- meanwhile, nakama/src/matchmaking/gate.ts), but the ticket is spent.
	if not match_id then
		handle._nakama_ticket = nil
		if handle._nakama_requeue then
			MPAPI.sendDebugMessage('[mmdbg] matched group refused by the server, queueing again')
			handle._nakama_requeue()
		else
			mm.remove_handle(handle)
			handle:_fire(MPAPI.MatchmakingEvent.ERROR, MPAPI.make_error(MPAPI.ErrorKind.SERVER, 'match refused'))
		end
		return
	end
	handle.match_id = match_id
	for _, h in ipairs(mm.handles) do
		if h ~= handle then
			MPAPI._internal.mm.leave_handle_quietly(h)
		end
	end
	mm.handles = { handle }
	handle:_fire(MPAPI.MatchmakingEvent.MATCH_FOUND, { matchId = match_id, modId = handle.mod_id, gameMode = handle.game_mode })

	local lobby = MPAPI._internal.lobby.nakama_join_match(handle.mod_id, match_id)
	if not lobby then
		handle._lobby_ready = true
		handle:_fire(MPAPI.MatchmakingEvent.ERROR, 'could not join the matched lobby')
		return
	end
	lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
		handle._lobby_ready = true
		handle:_fire(MPAPI.MatchmakingEvent.LOBBY_READY, lobby)
	end)
	lobby:on(MPAPI.LobbyEvent.ERROR, function(err)
		handle._lobby_ready = true
		handle:_fire(MPAPI.MatchmakingEvent.ERROR, 'lobby join failed: ' .. tostring(err))
	end)
	-- Nakama has no separate resolve message: the lobby's result is it.
	lobby:on(MPAPI.LobbyEvent.GAME_ENDED, function()
		if handle.match_id == match_id then
			handle:_fire(MPAPI.MatchmakingEvent.MATCH_RESOLVED, nil)
			mm.remove_handle(handle)
		end
	end)
end

-- Another queue's ticket, dropped because this one matched first.
function MPAPI._internal.mm.leave_handle_quietly(handle)
	handle._left = true
	if handle._nakama_ticket then
		MPAPI.networking.nakama_lobby.unqueue(handle._nakama_ticket)
	end
	handle:_fire(MPAPI.MatchmakingEvent.LEFT, nil)
end

-- A ranked queue the server cancelled (api/connection/moderation.lua), its
-- ticket already given up. The handle still gets a MatchmakingEvent.ERROR (the
-- path client-side prechecks use too, so PvP's/SPDRN's handle:on("error", ...)
-- listeners stop their own "Queueing..." UI), and MPAPI shows the explanation
-- itself via ui/ranked_queue_cancelled_overlay.lua, once, for every mod.
function MPAPI._internal.mm.cancel_handle(handle, reason)
	local mm = MPAPI._internal.mm
	local kind = reason == 'launcher_outdated'
		and MPAPI.ErrorKind.RANKED_LAUNCHER_OUTDATED
		or MPAPI.ErrorKind.RANKED_MODS_OUTDATED
	handle:_fire(MPAPI.MatchmakingEvent.ERROR, MPAPI.make_error(kind, 'Ranked queue cancelled: ' .. tostring(reason)))
	mm.remove_handle(handle)

	if MPAPI.show_ranked_queue_cancelled_notice then
		MPAPI.show_ranked_queue_cancelled_notice(reason)
	end
end
