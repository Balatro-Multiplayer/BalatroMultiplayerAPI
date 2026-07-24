local connection = {}

-- Single source of truth for connection states lives in domain/connection_state.lua
-- (loaded before networking), referenced here so the state machine and the api/
-- layer agree on the values.
local STATES = MPAPI.ConnectionState

function connection.new(opts)
	local self = {
		mqtt = opts.mqtt_client,
		api = opts.api_client,
		steam = opts.steam,
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

-- Shared handler for a successful auth response from the server.
function connection:_handle_auth_success(data)
	self.jwt_token = data.token
	self.player_id = data.player and data.player.id or nil
	self.is_temp = data.player and data.player.isTemp or false

	if data.player then
		self.steam_name = data.player.steamName or self.steam_name
		self.discord_name = data.player.discordUsername or nil
		self.display_name = data.player.displayName or self.steam_name
		self.use_discord_name = data.player.useDiscordName or false
		self.preferred_joker = data.player.preferredJoker or 'j_joker'
		self.discord_linked = data.player.discordLinked or false
		if data.player.privileges then
			self.privileges = data.player.privileges
		end
		self.chat_enabled = data.player.chatEnabled or false
		self.chat_blocked = data.player.chatBlocked or false
		self.mute_list = {}
		for _, id in ipairs(data.player.mutedPlayerIds or {}) do
			self.mute_list[id] = true
		end
	end

	self.lobby_data = data.lobby or nil

	if not self.player_id or not self.jwt_token then
		set_state(self, STATES.DISCONNECTED, { error = 'Auth response missing player ID or token' })
		return
	end

	self:_mqtt_connect_with_credentials()
end

-- §4.2/§4.3: no persisted credentials -- every launch does a fresh, silent
-- Steam ticket handshake instead of preferring a cached refresh token.
function connection:_do_auth()
	set_state(self, STATES.AUTHENTICATING)
	self:_try_steam_auth()
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
		if self.auth_ticket_handle then
			self.steam.cancel_auth_ticket(self.auth_ticket_handle)
			self.auth_ticket_handle = nil
		end

		if err then
			set_state(self, STATES.DISCONNECTED, { error = 'Steam auth failed: ' .. tostring(err) })
			return
		end

		if data.tosRequired then
			self._pending_tos_token = data.token
			set_state(self, STATES.TOS_REQUIRED, { steam_name = self.steam_name, tos_update = data.tosUpdate or false })
			return
		end

		self:_handle_auth_success(data)
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

function connection:_mqtt_connect_with_credentials()
	set_state(self, STATES.CONNECTING)

	local SEP = '\1'
	local cfg = self.config

	self.mqtt.on_connect = function()
		set_state(self, STATES.CONNECTED)

		if self.lobby_data then
			fire(self, STATES.CONNECTED, { reconnected_lobby = self.lobby_data })
			self.lobby_data = nil
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

	self.mqtt.on_error = function(msg)
		if self.state == STATES.CONNECTING then
			set_state(self, STATES.DISCONNECTED, { error = 'MQTT connection failed: ' .. tostring(msg) })
		else
			fire(self, self.state, { error = tostring(msg) })
		end
	end

	self.mqtt.on_disconnect = function()
		set_state(self, STATES.DISCONNECTED)
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
	self.player_id = nil
	self.jwt_token = nil
	self.lobby_data = nil
end

MPAPI.networking.connection = connection
