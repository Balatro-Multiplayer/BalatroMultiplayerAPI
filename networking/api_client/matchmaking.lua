local api_client = MPAPI.networking.api_client

function api_client:queue_matchmaking(token, opts, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	local body = api_client.json_encode(opts)
	self.mqtt:http_post_auth(self.base_url .. '/api/matchmaking/queue', body, token)
end

function api_client:leave_matchmaking_queue(token, opts, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	local body = api_client.json_encode(opts)
	self.mqtt:http_delete_with_body_auth(self.base_url .. '/api/matchmaking/queue', body, token)
end

function api_client:leave_all_matchmaking_queues(token, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_delete_auth(self.base_url .. '/api/matchmaking/queue/all', token)
end

function api_client:get_matchmaking_status(token, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_get_auth(self.base_url .. '/api/matchmaking/queue', token)
end

function api_client:report_match_result(token, match_id, placements, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	local body = api_client.json_encode({ placements = placements })
	self.mqtt:http_post_auth(self.base_url .. '/api/matchmaking/matches/' .. match_id .. '/result', body, token)
end

-- Signal that the run has begun, so the server can stamp the start time for
-- server-measured timing leaderboards. Host only; idempotent server-side.
function api_client:mark_run_start(token, match_id, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	self.mqtt:http_post_auth(self.base_url .. '/api/matchmaking/matches/' .. match_id .. '/start', '{}', token)
end

function api_client:get_matchmaking_rating(token, mod_id, game_mode, season, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	local url = self.base_url .. '/api/matchmaking/ratings?modId=' .. mod_id ..
		'&gameMode=' .. game_mode
	if season ~= nil then
		url = url .. '&season=' .. tostring(season)
	end
	self.mqtt:http_get_auth(url, token)
end

function api_client:get_matchmaking_leaderboard(token, mod_id, game_mode, season, limit, offset, callback)
	if not self:_transport_ready() then
		callback(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'MQTT thread not running'), nil)
		return
	end
	self:_setup_json_callback(callback)
	local url = self.base_url .. '/api/matchmaking/leaderboard?modId=' .. mod_id ..
		'&gameMode=' .. game_mode
	if season ~= nil then
		url = url .. '&season=' .. tostring(season)
	end
	url = url .. '&limit=' .. tostring(limit or 100) .. '&offset=' .. tostring(offset or 0)
	self.mqtt:http_get_auth(url, token)
end
