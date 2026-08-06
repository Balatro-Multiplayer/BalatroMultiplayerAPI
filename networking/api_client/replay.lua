local api_client = MPAPI.networking.api_client

-- Phase 6 (compact action log): download a stored run's replay -- returns
-- {run={...}, logs=[{playerId, compressedEvents, carbonHash, eventCount, status}]}.
-- `compressedEvents` is still gzip+base64 (MPAPI.decompress_str, then
-- MPAPI.json_decode) -- the caller merges every player's decoded event array
-- into one timeline via MPAPI.playback.build_timeline (api/playback/timeline.lua).
function api_client:get_replay(token, run_id, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(self.base_url .. '/api/runs/' .. run_id .. '/replay', token)
end

-- §22.2 (+pagination): a player's own past run ids (GET /api/runs/mine) --
-- the discovery step a "My Matches" replay list needs. opts = {page=,
-- page_size=} (both optional; server defaults to page 1, pageSize 20).
-- Returns {runs = [{id, lobbyCode, modId, lobbyType, status, startedAt,
-- finalizedAt}, ...], total, page, pageSize}.
function api_client:get_my_runs(token, opts, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	opts = opts or {}
	local url = self.base_url .. '/api/runs/mine?page=' .. tostring(opts.page or 1)
		.. '&pageSize=' .. tostring(opts.page_size or 20)
	self.mqtt:http_get_auth(url, token)
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
