local api_client = MPAPI.networking.api_client

-- Phase 6 (compact action log): download a stored run's replay -- returns
-- {run={...}, logs=[{playerId, compressedEvents, carbonHash, eventCount, status}]}.
-- `compressedEvents` is still gzip+base64 (MP.UTILS.decompress_str, then
-- json.decode); the caller (e.g. PvP's ghost_replay.lua) is responsible for
-- turning the decoded event array into a replay via LOG_PARSER.carbon_to_replay.
function api_client:get_replay(token, run_id, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(self.base_url .. '/api/runs/' .. run_id .. '/replay', token)
end

-- Phase 7 (live spectating): request a short-lived spectator token scoped to
-- `code`, plus a one-time best-effort state snapshot. Returns {token, snapshot}.
-- The caller reconnects (or connects a second MQTT client) using this token as
-- the CONNECT password to receive the live lobby/{code}/+/+ stream read-only.
function api_client:spectate_lobby(token, code, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(self.base_url .. '/api/lobbies/' .. code .. '/spectate', token)
end

-- Phase 9 (reconnect tail-replay): fetch `player_id`'s buffered game_log_event
-- stream for `lobby_code` since `since_t` (their own elapsed-ms marker, see
-- MP.RLOG._last_seen_t) -- reads the server's LIVE in-memory buffer, not a
-- finalized run, since the match is still active. Returns {events=[{t,
-- opcode, args}, ...]}, [] when nothing new. Used by a reconnecting client to
-- catch up on the opponent's actions broadcast while it was disconnected
-- (MQTT doesn't backlog non-retained topic messages).
function api_client:get_tail(token, lobby_code, player_id, since_t, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(
		self.base_url .. '/api/runs/' .. lobby_code .. '/players/' .. player_id .. '/tail?since_t=' .. tostring(since_t),
		token
	)
end
