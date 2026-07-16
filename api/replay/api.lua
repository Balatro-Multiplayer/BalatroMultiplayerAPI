MPAPI.replay = MPAPI.replay or {}

-- Phase 6: download a stored run's replay. callback(err, data) where data is
-- {run={...}, logs=[{playerId, compressedEvents, carbonHash, eventCount, status}]}.
MPAPI.replay.get = function(run_id, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:get_replay(conn.jwt_token, run_id, callback)
end

-- Phase 7: request a spectator token + one-time snapshot for a lobby.
-- callback(err, data) where data is {token, snapshot}.
MPAPI.replay.spectate_lobby = function(code, callback)
	local conn = MPAPI.get_connection()
	if not conn then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn.api:spectate_lobby(conn.jwt_token, code, callback)
end
