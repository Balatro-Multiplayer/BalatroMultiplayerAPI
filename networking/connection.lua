local connection = {}

-- Single source of truth for connection states lives in domain/connection_state.lua
-- (loaded before networking), referenced here so the state machine and the api/
-- layer agree on the values.
local STATES = MPAPI.ConnectionState

-- Backoff for a lightweight, HTTP-free MQTT-only reconnect after an
-- unsolicited drop (see connection:_attempt_mqtt_reconnect below) -- mirrors
-- the cadence networking/mqtt_thread.lua's request_with_retry already uses
-- for HTTP retries, kept as separate constants since that runs on a
-- different LÖVE thread with no shared state. After MQTT_RECONNECT_MAX_ATTEMPTS
-- silent attempts (or an explicit auth deny -- an expired/revoked JWT,
-- changed ToS, a new ban -- none of which a retry can fix), falls back to a
-- full connect() (fresh Steam ticket + HTTP re-auth).
local MQTT_RECONNECT_BACKOFF = { 0.3, 0.8, 1.5 }
local MQTT_RECONNECT_MAX_ATTEMPTS = 4

-- Placeholder custom id for Nakama's Steam login (see _try_nakama_auth);
-- the server replaces it.
local NAKAMA_STEAM_LOGIN_ID = 'steam-ticket'

-- Device ids for dev impersonation under nakama_only (see
-- _try_nakama_device_auth); the same prefix nakama_lobby.lua uses.
local NAKAMA_DEV_DEVICE_PREFIX = 'bmp-dev-'

-- Seconds between resends of the Nakama login. A fresh Steam ticket is only
-- valid once Steam's backend has registered it; sent straight away (the
-- Nakama request goes out on the same frame), Steam can answer 101 "Invalid
-- ticket". Resending the same ticket a moment later succeeds.
local NAKAMA_LOGIN_RETRY_INTERVALS = { 0.5, 0.5, 1, 1 }

-- Always the most recently constructed instance (connection.new() can run
-- more than once per session - e.g. MPAPI.reconnect() - each call replacing
-- the previous instance). The launcher-integrity challenge-answered callback
-- below is only ever registered once (challenge_callback_registered), but
-- needs to keep publishing through whichever connection is actually live
-- right now, not whichever one happened to be live when it was registered.
local current_instance = nil
local challenge_callback_registered = false

function connection.new(opts)
	local self = {
		mqtt = opts.mqtt_client,
		api = opts.api_client,
		steam = opts.steam,
		-- Set when logging in through Nakama (config use_nakama_auth).
		nakama_client = opts.nakama_client,
		nakama_session = nil,
		config = opts.config or {},
		state = STATES.DISCONNECTED,

		player_id = nil,
		jwt_token = nil,
		steam_name = nil,
		display_name = nil,
		use_discord_name = false,
		preferred_joker = 'j_joker',
		privileges = {},
		discord_linked = false,
		discord_name = nil,
		is_temp = false,
		chat_enabled = false,
		chat_blocked = false,
		-- {[player_id]=true} for O(1) chat-filter lookups. Fetched once per auth
		-- response (see _handle_auth_success below) and kept current locally by
		-- mute_player/unmute_player for the rest of the session (see profile.lua).
		mute_list = {},
		auth_ticket_handle = nil,

		lobby_data = nil,
		on_state_change = nil,

		-- Stored when the server rejects auth with tosRequired=true
		_pending_tos_token = nil,
	}

	setmetatable(self, { __index = connection })
	current_instance = self

	-- Deferred to here (runtime, first construction) rather than this file's
	-- own top level - core.lua loads networking/connection.lua before
	-- anticheat/launcher_channel.lua, so MPAPI.on_launcher_challenge_answered
	-- doesn't exist yet at this file's load time. By the time any
	-- connection.new() call happens, every mod file has already loaded.
	if not challenge_callback_registered and MPAPI.on_launcher_challenge_answered then
		challenge_callback_registered = true
		MPAPI.on_launcher_challenge_answered(function(result)
			if current_instance then
				current_instance:_publish_challenge_response(result)
			end
		end)
	end

	return self
end

function connection:get_state()
	return self.state
end

local function fire(self, new_state, context)
	if self.on_state_change then
		local ok, err = pcall(self.on_state_change, new_state, context)
		if not ok then
			MPAPI.sendWarnMessage('on_state_change error: ' .. tostring(err))
		end
	end
end

local function set_state(self, new_state, context)
	local old = self.state
	self.state = new_state
	fire(self, new_state, context or { old_state = old })
end

-- The server's player object (the API's playerPayload, or Nakama's
-- playerView) onto the connection.
function connection:_apply_player(player)
	self.steam_name = player.steamName or self.steam_name
	self.discord_name = player.discordUsername or nil
	self.display_name = player.displayName or self.steam_name
	self.use_discord_name = player.useDiscordName or false
	self.preferred_joker = player.preferredJoker or 'j_joker'
	self.discord_linked = player.discordLinked or false
	if player.privileges then
		self.privileges = player.privileges
	end
	self.chat_enabled = player.chatEnabled or false
	self.chat_blocked = player.chatBlocked or false
	self.mute_list = {}
	for _, id in ipairs(player.mutedPlayerIds or {}) do
		self.mute_list[id] = true
	end
end

-- A changed account from Nakama ({player}: an account RPC's answer or an
-- ACCOUNT_UPDATED push), as the MQTT account/* topics did.
function connection:_on_account_updated(data)
	if type(data) ~= 'table' or type(data.player) ~= 'table' or self.state ~= STATES.CONNECTED then
		return
	end
	self:_apply_player(data.player)
	fire(self, self.state, { player_update = true })
end

-- Shared handler for a successful auth response from the server.
function connection:_handle_auth_success(data)
	self.jwt_token = data.token
	self.player_id = data.player and data.player.id or nil
	self._check_nakama_lobby = true
	self.is_temp = data.player and data.player.isTemp or false

	if data.player then
		self:_apply_player(data.player)
	end

	self.lobby_data = data.lobby or nil

	if not self.player_id or not self.jwt_token then
		set_state(self, STATES.DISCONNECTED, { error = 'Auth response missing player ID or token' })
		return
	end

	if self:_nakama_only() then
		self:_nakama_connect()
	else
		self:_mirror_consent_to_nakama(data.player)
		self:_mqtt_connect_with_credentials()
	end
end

-- An API login with Nakama lobbies on (use_nakama_lobbies, not nakama_only):
-- Nakama's chat checks its own copy of the ToS and chat consent, so the
-- API's answer is passed on (tos_accept; chat-eligible only when the API
-- has chat on, not eligible only when it blocks it).
function connection:_mirror_consent_to_nakama(player)
	local NL = MPAPI.networking.nakama_lobby
	if not player or not NL or not NL.enabled() then
		return
	end
	local body = {}
	if player.chatEnabled then
		body.chatEligible = true
	elseif player.chatBlocked then
		body.chatEligible = false
	end
	NL.rpc('tos_accept', body, function(err)
		if err then
			MPAPI.sendWarnMessage('[nakama] Could not pass the ToS on: ' .. tostring(err))
		end
	end)
end

-- §4.2/§4.3: no persisted credentials -- every launch does a fresh, silent
-- Steam ticket handshake instead of preferring a cached refresh token.
function connection:_do_auth()
	set_state(self, STATES.AUTHENTICATING)
	if self:_nakama_only() then
		self:_try_nakama_only_auth()
	elseif self.nakama_client then
		self:_try_nakama_auth()
	else
		self:_try_steam_auth()
	end
end

-- Shared handler for the /steam and /nakama login responses.
function connection:_handle_login_response(data)
	if data.tosRequired then
		self._pending_tos_token = data.token
		set_state(self, STATES.TOS_REQUIRED, { steam_name = self.steam_name, tos_update = data.tosUpdate or false })
		return
	end

	self:_handle_auth_success(data)
end

function connection:_cancel_auth_ticket()
	if self.auth_ticket_handle then
		self.steam.cancel_auth_ticket(self.auth_ticket_handle)
		self.auth_ticket_handle = nil
	end
end

function connection:_try_steam_auth()
	if not self.steam or not self.steam.available() then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam is not available' })
		return
	end

	local ticket_data, ticket_err = self.steam.get_auth_ticket()
	if not ticket_data then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam ticket failed: ' .. tostring(ticket_err) })
		return
	end

	self.auth_ticket_handle = ticket_data.handle
	self.steam_name = self.steam.get_persona_name() or 'Player'

	self.mqtt:start_thread()

	self.api:authenticate_steam(ticket_data.ticket, self.steam_name, function(err, data)
		self:_cancel_auth_ticket()

		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'Steam auth failed: ' .. tostring(err) })
			return
		end

		self:_handle_login_response(data)
	end)
end

-- Same as _try_steam_auth, except the Steam ticket goes to Nakama, which
-- verifies it and returns a Nakama session; the API then signs the player in
-- from that session (POST /api/auth/nakama) and the rest is unchanged.
--
-- Custom auth, not authenticate_steam: Nakama's built-in Steam check needs
-- Balatro's publisher key. The server's runtime hook checks the ticket in
-- vars.steam_ticket and replaces the placeholder id with "steam:<steamid>".
function connection:_try_nakama_auth()
	if not self.steam or not self.steam.available() then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam is not available' })
		return
	end

	local ticket_data, ticket_err = self.steam.get_auth_ticket()
	if not ticket_data then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam ticket failed: ' .. tostring(ticket_err) })
		return
	end

	self.auth_ticket_handle = ticket_data.handle
	self.steam_name = self.steam.get_persona_name() or 'Player'

	-- Still needed: the API calls go over the MQTT thread's HTTP transport.
	self.mqtt:start_thread()

	local client = self.nakama_client
	client.authenticate_custom(NAKAMA_STEAM_LOGIN_ID, { steam_ticket = ticket_data.ticket }, true, nil, function(session)
		self:_cancel_auth_ticket()
		if self.state ~= STATES.AUTHENTICATING then
			return
		end

		if not session or session.error then
			local message = session and (session.message or session.error) or 'no response'
			set_state(self, STATES.DISCONNECTED, { error = 'Nakama auth failed: ' .. tostring(message) })
			return
		end

		self.nakama_session = session
		client.set_bearer_token(session.token)

		self.api:authenticate_nakama(session.token, self.steam_name, function(err, data)
			if err then
				set_state(self, STATES.DISCONNECTED, { error = 'Nakama login rejected: ' .. tostring(err) })
				return
			end

			self:_handle_login_response(data)
		end)
	end, NAKAMA_LOGIN_RETRY_INTERVALS)
end

-- True when the client talks to Nakama alone (config nakama_only): no API
-- requests and no MQTT. Login is a Nakama session plus the session_init RPC,
-- which answers what /api/auth/nakama did.
function connection:_nakama_only()
	return self.nakama_client ~= nil and MPAPI.config ~= nil and MPAPI.config.nakama_only == true
end

-- Calls a Nakama RPC on this connection's client. cb(err_message, data).
function connection:_nakama_rpc(id, body, cb)
	local encoded = (body and next(body)) and MPAPI.json_encode(body) or '{}'
	self.nakama_client.rpc_func(id, encoded, nil, function(result)
		if not result or result.error then
			local e = result and result.error
			cb(type(e) == 'table' and e.message or (result and result.message) or ('RPC ' .. id .. ' failed'))
			return
		end
		local ok, data = pcall(MPAPI.json_decode, result.payload or '{}')
		if not ok or type(data) ~= 'table' then
			cb('RPC ' .. id .. ' returned bad JSON')
			return
		end
		cb(nil, data)
	end)
end

-- With a fresh Nakama session: fetch the account (session_init) and carry on
-- exactly as after an API login. The session token stands in for the JWT.
function connection:_nakama_session_init(session)
	self.nakama_session = session
	self.nakama_client.set_bearer_token(session.token)
	self:_nakama_rpc('session_init', { steamName = self.steam_name }, function(err, data)
		if self.state ~= STATES.AUTHENTICATING then
			return
		end
		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'Nakama login rejected: ' .. tostring(err) })
			return
		end
		data.token = session.token
		self:_handle_login_response(data)
	end)
end

function connection:_nakama_auth_failed(session)
	local message = session and (session.message or session.error) or 'no response'
	if type(message) == 'table' then
		message = message.message or 'error'
	end
	set_state(self, STATES.DISCONNECTED, { error = 'Nakama auth failed: ' .. tostring(message) })
end

function connection:_try_nakama_only_auth()
	if not self.steam or not self.steam.available() then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam is not available' })
		return
	end

	local ticket_data, ticket_err = self.steam.get_auth_ticket()
	if not ticket_data then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam ticket failed: ' .. tostring(ticket_err) })
		return
	end

	self.auth_ticket_handle = ticket_data.handle
	self.steam_name = self.steam.get_persona_name() or 'Player'

	self.nakama_client.authenticate_custom(NAKAMA_STEAM_LOGIN_ID, { steam_ticket = ticket_data.ticket }, true, nil, function(session)
		self:_cancel_auth_ticket()
		if self.state ~= STATES.AUTHENTICATING then
			return
		end
		if not session or session.error then
			self:_nakama_auth_failed(session)
			return
		end
		self:_nakama_session_init(session)
	end, NAKAMA_LOGIN_RETRY_INTERVALS)
end

-- Dev only, the nakama_only counterpart of impersonation: a device login
-- keyed by the impersonation target (needs the server's ALLOW_DEVICE_AUTH).
function connection:_try_nakama_device_auth(target)
	local key = target.playerId or target.steamId or target.discordId or target.steamName or 'dev'
	self.steam_name = target.steamName or ('Dev-' .. tostring(key):sub(1, 8))
	self.nakama_client.authenticate_device(NAKAMA_DEV_DEVICE_PREFIX .. tostring(key), nil, true, nil, function(session)
		if self.state ~= STATES.AUTHENTICATING then
			return
		end
		if not session or session.error then
			self:_nakama_auth_failed(session)
			return
		end
		self:_nakama_session_init(session)
	end)
end

-- Logged in through Nakama alone: open the socket (it carries the server's
-- pushes) and go CONNECTED; MQTT never starts.
function connection:_nakama_connect()
	set_state(self, STATES.CONNECTING)
	local NL = MPAPI.networking.nakama_lobby
	NL.keep_socket_open(true)
	NL.ensure_socket(function(ok, err)
		if self.state ~= STATES.CONNECTING then
			return
		end
		if not ok then
			NL.keep_socket_open(false)
			set_state(self, STATES.DISCONNECTED, { error = 'Nakama socket failed: ' .. tostring(err) })
			return
		end
		set_state(self, STATES.CONNECTED)
		if self._check_nakama_lobby then
			self._check_nakama_lobby = nil
			self:_check_nakama_lobby_seat()
		end
	end)
end

function connection:_try_dev_auth()
	set_state(self, STATES.AUTHENTICATING)
	self.mqtt:start_thread()

	local dev_name = (self.steam and self.steam.available() and self.steam.get_persona_name()) or self.config.dev_name or 'DevPlayer'
	self.steam_name = dev_name

	self.api:authenticate_dev(dev_name, function(err, data)
		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'Dev auth failed: ' .. tostring(err) })
			return
		end
		self:_handle_auth_success(data)
	end)
end

-- Dev-only: authenticate as an existing player (real players row) instead of via
-- Steam. target is a table with one of: playerId, steamId, discordId, steamName.
-- Lets a second instance act as a different real account for matchmaking testing.
function connection:_try_impersonate_auth(target)
	set_state(self, STATES.AUTHENTICATING)
	if self:_nakama_only() then
		self:_try_nakama_device_auth(target)
		return
	end
	self.mqtt:start_thread()

	self.api:authenticate_impersonate(target, function(err, data)
		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'Impersonation auth failed: ' .. tostring(err) })
			return
		end
		self:_handle_auth_success(data)
	end)
end

-- Entry point called by the UI / game to initiate a connection.
function connection:connect()
	if self.state ~= STATES.DISCONNECTED then
		fire(self, self.state, { error = 'Already ' .. self.state })
		return
	end

	if not self.steam or not self.steam.available() then
		set_state(self, STATES.DISCONNECTED, { error = 'Steam is not available' })
		return
	end

	self.steam_name = self.steam.get_persona_name() or 'Player'

	self:_do_auth()
end

-- Called by the UI after the user reads and accepts the ToS / Privacy Policy.
-- chat_eligible: boolean computed client-side from birthdate (never sent raw).
function connection:accept_tos(chat_eligible)
	if self.state ~= STATES.TOS_REQUIRED or not self._pending_tos_token then
		return
	end

	set_state(self, STATES.AUTHENTICATING)
	local token = self._pending_tos_token
	self._pending_tos_token = nil
	if self:_nakama_only() then
		local body = {}
		if chat_eligible ~= nil then
			body.chatEligible = chat_eligible and true or false
		end
		self:_nakama_rpc('tos_accept', body, function(err, data)
			if self.state ~= STATES.AUTHENTICATING then
				return
			end
			if err then
				set_state(self, STATES.DISCONNECTED, { error = 'ToS acceptance failed: ' .. tostring(err) })
				return
			end
			data.token = token
			self:_handle_auth_success(data)
		end)
		return
	end
	self.api:accept_tos_update(token, chat_eligible, function(err, data)
		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'ToS acceptance failed: ' .. tostring(err) })
			return
		end
		self:_handle_auth_success(data)
	end)
end

-- Called by the UI when the user declines the ToS.
-- Disconnects fully; the prompt will appear again on the next connection attempt.
function connection:decline_tos()
	self._pending_tos_token = nil
	if self.mqtt then
		self.mqtt:disconnect()
	end
	set_state(self, STATES.DISCONNECTED)
end

-- A seat in a Nakama lobby (config use_nakama_lobbies) survives a game
-- restart the same way an MQTT lobby membership does; lobby_current finds it,
-- and it goes out as a second CONNECTED with reconnected_lobby, like the
-- API's lobby_data. Once per login, and not while already in a lobby.
function connection:_check_nakama_lobby_seat()
	local lobby = MPAPI._internal.lobby
	if not lobby or not lobby.nakama_enabled or not lobby.nakama_enabled() or lobby.current then
		return
	end
	lobby.nakama_check_current(function(lobby_data)
		if lobby_data and self.state == STATES.CONNECTED and not lobby.current then
			fire(self, STATES.CONNECTED, { reconnected_lobby = lobby_data })
		end
	end)
end

function connection:_mqtt_connect_with_credentials()
	set_state(self, STATES.CONNECTING)

	local SEP = '\1'
	local cfg = self.config

	self.mqtt.on_connect = function()
		-- Fully back online -- reset the lightweight-reconnect attempt
		-- counter so a *later*, unrelated drop starts its own retry budget
		-- fresh rather than continuing to erode whatever attempt count this
		-- connect happened to succeed on (see _attempt_mqtt_reconnect).
		self._mqtt_reconnect_attempt = nil

		set_state(self, STATES.CONNECTED)

		if self.lobby_data then
			fire(self, STATES.CONNECTED, { reconnected_lobby = self.lobby_data })
			self.lobby_data = nil
		end
		if self._check_nakama_lobby then
			self._check_nakama_lobby = nil
			self:_check_nakama_lobby_seat()
		end

		if self.player_id then
			-- Every player-addressed push (account/*, and §22.5's replay-tail
			-- reconnect catch-up) lives under this one topic namespace -- the
			-- server's own ACL already allows the whole player/{id}/# tree to
			-- this player, not just player/{id}/account/#.
			local topic = 'player/' .. self.player_id .. '/#'
			MPAPI.sendDebugMessage('Subscribing to ' .. topic)
			self.mqtt:subscribe(topic, 1, function(t, payload)
				self:_handle_player_notification(t, payload)
			end)
		end
	end

	-- A failed CONNECT can surface as either on_error or on_disconnect
	-- depending on exactly how/where it fails (bad auth, network refusal,
	-- etc.) -- both branches below route a failure during an in-flight
	-- lightweight-reconnect attempt (self._mqtt_reconnect_attempt set by
	-- _attempt_mqtt_reconnect) through the same _handle_mqtt_reconnect_failure,
	-- so the backoff/max-attempts/fallback logic lives in exactly one place
	-- regardless of which signal actually fires.
	self.mqtt.on_error = function(msg)
		if self._mqtt_reconnect_attempt then
			self:_handle_mqtt_reconnect_failure(msg)
		elseif self.state == STATES.CONNECTING then
			set_state(self, STATES.DISCONNECTED, { error = 'MQTT connection failed: ' .. tostring(msg) })
		else
			fire(self, self.state, { error = tostring(msg) })
		end
	end

	self.mqtt.on_disconnect = function()
		if self._mqtt_reconnect_attempt then
			self:_handle_mqtt_reconnect_failure('disconnected before CONNACK')
			return
		end

		-- An unsolicited drop doesn't clear player_id/jwt_token (only the
		-- explicit connection:disconnect() method does, below) -- so if we
		-- still have both, this is a real mid-session mqtt reconnect
		-- opportunity: redial with the same cached credentials instead of
		-- just sitting DISCONNECTED until the player notices and manually
		-- reconnects from the main menu. This is what closes the race that
		-- let a legitimately-reconnected-but-still-mid-match player get
		-- auto-forfeited by the server's grace-period timer anyway.
		if self.player_id and self.jwt_token then
			self:_attempt_mqtt_reconnect(1)
		else
			set_state(self, STATES.DISCONNECTED)
		end
	end

	local connect_msg = table.concat({
		'connect',
		cfg.mqtt_broker or '127.0.0.1',
		tostring(cfg.mqtt_port or 1883),
		tostring(cfg.mqtt_secure or false),
		self.player_id,
		tostring(cfg.mqtt_keep_alive or 60),
		tostring(cfg.mqtt_secure and cfg.mqtt_verify or false),
		self.player_id,
		self.jwt_token,
	}, SEP)

	self.mqtt.tx_channel:push(connect_msg)
end

-- Lightweight, HTTP-free MQTT-only reconnect after an unsolicited drop, using
-- the still-cached player_id/jwt_token. Server-side, the same JWT is valid
-- for a fresh MQTT CONNECT within its normal expiry (the session isn't torn
-- down on a plain disconnect while still mid-lobby -- see
-- emqx-auth.service.ts's authenticateClient/hasActiveSession), so no Steam
-- ticket or HTTP round trip is needed unless this keeps failing.
function connection:_attempt_mqtt_reconnect(attempt)
	self._mqtt_reconnect_attempt = attempt
	set_state(self, STATES.RECONNECTING, { attempt = attempt })
	self:_mqtt_connect_with_credentials()
end

-- Shared failure path for a lightweight reconnect attempt, regardless of
-- whether it surfaced via on_error or on_disconnect (see
-- _mqtt_connect_with_credentials). Retries with backoff up to
-- MQTT_RECONNECT_MAX_ATTEMPTS times; beyond that (or if the server explicitly
-- denies the fresh CONNECT -- an expired/revoked JWT, changed ToS, a new ban,
-- none of which a retry can fix), falls back to a full connect() (fresh Steam
-- ticket + HTTP re-auth).
function connection:_handle_mqtt_reconnect_failure(msg)
	local attempt = self._mqtt_reconnect_attempt or 1

	if attempt >= MQTT_RECONNECT_MAX_ATTEMPTS then
		self._mqtt_reconnect_attempt = nil
		set_state(self, STATES.DISCONNECTED, { error = 'MQTT reconnect failed: ' .. tostring(msg) })
		self:connect()
		return
	end

	set_state(self, STATES.RECONNECTING, { attempt = attempt, error = tostring(msg) })

	local delay = MQTT_RECONNECT_BACKOFF[attempt] or MQTT_RECONNECT_BACKOFF[#MQTT_RECONNECT_BACKOFF]
	G.E_MANAGER:add_event(Event({
		trigger = 'after',
		delay = delay,
		blockable = false,
		blocking = false,
		func = function()
			if self.player_id and self.jwt_token then
				self:_attempt_mqtt_reconnect(attempt + 1)
			end
			return true
		end,
	}))
end

function connection:_handle_player_notification(topic, payload)
	local full_subtopic = topic:match('^player/[^/]+/(.+)$')
	if not full_subtopic then
		return
	end

	MPAPI.sendDebugMessage('Player notification: ' .. full_subtopic .. ' payload=' .. tostring(payload))

	local function decode_payload()
		local ok, data = pcall(function()
			if json and json.decode then
				return json.decode(payload)
			end
			return require('json').decode(payload)
		end)
		return ok and data or nil
	end

	-- §22.5: reconnect catch-up pushed directly to this player, instead of a
	-- REST pull -- surfaced to consumer mods (e.g. PvP's reconnect_tail.lua)
	-- via the same on_connection_state_change context every other player
	-- update already flows through, rather than a new bespoke callback.
	if full_subtopic == 'replay-tail' then
		local data = decode_payload()
		if data and data.tails then
			fire(self, self.state, { replay_tail = data })
		else
			MPAPI.sendWarnMessage('replay-tail: failed to parse payload')
		end
		return
	end

	-- Launcher-integrity challenge (see launcher-integrity.service.ts) --
	-- issued on every fresh MQTT connect regardless of game mode, so this
	-- always relays to MPAPI.anticheat.answer_challenge(), which is always
	-- safely callable (see anticheat/launcher_channel.lua) and self-refuses
	-- immediately for Casual / non-BET launches rather than needing a mode
	-- check here.
	if full_subtopic == 'challenge' then
		local data = decode_payload()
		if data and data.type == 'issued' and data.challengeId then
			self:_answer_launcher_challenge(data.challengeId, data.kind, data.nonce)
		elseif data and data.type == 'verified' then
			-- The server's actual verdict on our last response, not just
			-- confirmation BET answered - see anticheat/launcher_channel.lua's
			-- A.server_verified doc comment for why this is the one flag
			-- safe to gate a Ranked queue button on.
			if MPAPI.anticheat and MPAPI.anticheat.mark_server_verified then
				MPAPI.anticheat.mark_server_verified()
			end
		elseif data and data.type == 'failed' then
			-- Deliberately silent - failing this challenge is the expected,
			-- normal outcome for any non-BET launch (Casual, private lobbies,
			-- or just not using the launcher at all), not something worth
			-- surfacing to the player. It doesn't disconnect either (see
			-- launcher-integrity.service.ts's failIntegrity()) - the only
			-- consequence is staying unverified, which the Ranked queue
			-- button(s) already reflect via MPAPI.is_launcher_verified().
		else
			MPAPI.sendWarnMessage('challenge: failed to parse payload')
		end
		return
	end

	local subtopic = full_subtopic:match('^account/(.+)$')
	if not subtopic then
		return
	end

	if subtopic == 'discord_linked' then
		local data = decode_payload()
		if data then
			self.discord_name = data.discordName or 'Linked'
			self.discord_linked = true
			MPAPI.sendDebugMessage('Discord linked, set discord_name=' .. tostring(self.discord_name))
			fire(self, self.state, { player_update = true })
		else
			MPAPI.sendWarnMessage('discord_linked: failed to parse payload')
		end
	elseif subtopic == 'discord_unlinked' then
		self.discord_name = nil
		self.discord_linked = false
		self.use_discord_name = false
		self.display_name = self.steam_name
		MPAPI.sendDebugMessage('Discord unlinked')
		fire(self, self.state, { player_update = true })
	elseif subtopic == 'preferred_joker_changed' then
		local data = decode_payload()
		if data then
			self.preferred_joker = data.preferredJoker or 'j_joker'
			MPAPI.sendDebugMessage('Preferred joker changed to: ' .. tostring(self.preferred_joker))
			fire(self, self.state, { player_update = true })
		end
	elseif subtopic == 'display_name_changed' then
		local data = decode_payload()
		if data then
			self.display_name = data.displayName or self.steam_name
			self.use_discord_name = data.useDiscordName or false
			MPAPI.sendDebugMessage('Display name changed to: ' .. tostring(self.display_name))
			fire(self, self.state, { player_update = true })
		end
	end
end

-- Relays a launcher-integrity challenge to the launcher via
-- MPAPI.anticheat.answer_challenge() - see anticheat/launcher_channel.lua.
-- Always safely callable: for Casual or a non-BET launch, that function
-- self-refuses immediately (no mode check needed here). The eventual answer
-- arrives asynchronously via the connection.new()-registered
-- on_launcher_challenge_answered callback, not a return value from here.
function connection:_answer_launcher_challenge(challenge_id, kind, nonce)
	if not MPAPI.anticheat or not MPAPI.anticheat.answer_challenge then
		return
	end
	MPAPI.anticheat.answer_challenge(challenge_id, kind, nonce, self.player_id)
end

-- Publishes a launcher-integrity challenge result to the one topic the
-- server's EMQX ACL lets this client publish to besides its own account
-- topics - see emqx-auth.service.ts's authorizePlayerNotificationTopic().
-- `result` is whatever anticheat/launcher_channel.lua's
-- run_challenge_answered_callbacks() produced: either
-- {challenge_id, refused = true}, {challenge_id, signature}, or
-- {challenge_id, signature, launcher_current, mods_current, stale_mod_ids}
-- (ranked_readiness only - see
-- RankedSupervisor::sendReadinessChallengeResponse()). launcher_current can
-- legitimately be `false`,
-- so its presence (not truthiness) is what selects that shape - see
-- RANKED_READINESS_SPEC.md in the server repo for the exact wire contract.
function connection:_publish_challenge_response(result)
	if not self.player_id then
		return
	end

	local body = { challengeId = result.challenge_id }
	if result.refused then
		body.refused = true
	elseif result.launcher_current ~= nil then
		body.response = {
			signature = result.signature,
			launcherCurrent = result.launcher_current,
			modsCurrent = result.mods_current,
			staleModIds = result.stale_mod_ids,
		}
	else
		body.response = result.signature
	end

	local topic = 'player/' .. self.player_id .. '/challenge-response'
	self.mqtt:publish(topic, MPAPI.json_encode(body), 1, false)
end

function connection:disconnect()
	if self.state == STATES.DISCONNECTED then
		return
	end

	if self.auth_ticket_handle and self.steam then
		self.steam.cancel_auth_ticket(self.auth_ticket_handle)
		self.auth_ticket_handle = nil
	end

	if self.mqtt then
		self.mqtt:disconnect()
	end

	set_state(self, STATES.DISCONNECTED)
	if MPAPI.networking.nakama_lobby then
		MPAPI.networking.nakama_lobby.reset()
	end
	self.player_id = nil
	self.jwt_token = nil
	self.nakama_session = nil
	self.lobby_data = nil
end

MPAPI.networking.connection = connection
