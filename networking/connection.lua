local connection = {}

-- Single source of truth for connection states lives in domain/connection_state.lua
-- (loaded before networking), referenced here so the state machine and the api/
-- layer agree on the values.
local STATES = MPAPI.ConnectionState

-- Placeholder custom id for Nakama's Steam login (see _try_steam_auth);
-- the server replaces it.
local NAKAMA_STEAM_LOGIN_ID = 'steam-ticket'

-- Device ids for dev impersonation (see _try_impersonate_auth).
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
		steam = opts.steam,
		nakama_client = opts.nakama_client,
		nakama_session = nil,
		config = opts.config or {},
		state = STATES.DISCONNECTED,

		-- The Nakama user id and session token.
		player_id = nil,
		session_token = nil,
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

		on_state_change = nil,

		-- Stored when session_init answers tosRequired=true
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

-- A failed connection: DISCONNECTED with the raw error for the log and the
-- MPAPI.OfflineReason the menu shows.
local function fail(self, offline_reason, message)
	set_state(self, STATES.DISCONNECTED, { error = message, offline_reason = offline_reason })
end

-- The offline reason for a request the server never answered
-- (config.secure: the endpoint uses TLS).
function connection:_no_answer_reason()
	local ossl = MPAPI.networking.openssl_ffi
	return MPAPI.offline_reason_for_no_answer(self.config.secure, ossl ~= nil and ossl.available())
end

-- The server's player object (Nakama's playerView) onto the connection.
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
-- ACCOUNT_UPDATED push).
function connection:_on_account_updated(data)
	if type(data) ~= 'table' or type(data.player) ~= 'table' or self.state ~= STATES.CONNECTED then
		return
	end
	self:_apply_player(data.player)
	fire(self, self.state, { player_update = true })
end

-- Shared handler for a successful login (session_init or tos_accept).
function connection:_handle_auth_success(data)
	self.session_token = data.token
	self.player_id = data.player and data.player.id or nil
	self._check_nakama_lobby = true
	self.is_temp = data.player and data.player.isTemp or false

	if data.player then
		self:_apply_player(data.player)
	end

	if not self.player_id or not self.session_token then
		fail(self, MPAPI.OfflineReason.OTHER, 'Auth response missing player ID or token')
		return
	end

	self:_nakama_connect()
end

-- §4.2/§4.3: no persisted credentials -- every launch does a fresh, silent
-- Steam ticket handshake instead of preferring a cached refresh token.
function connection:_do_auth()
	set_state(self, STATES.AUTHENTICATING)
	self:_try_steam_auth()
end

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

-- With a fresh Nakama session: fetch the account (session_init) and log in.
function connection:_nakama_session_init(session)
	self.nakama_session = session
	self.nakama_client.set_bearer_token(session.token)
	self:_nakama_rpc('session_init', { steamName = self.steam_name }, function(err, data)
		if self.state ~= STATES.AUTHENTICATING then
			return
		end
		if err then
			self:_login_refused('Nakama login rejected: ', err, MPAPI.OfflineReason.OTHER)
			return
		end
		data.token = session.token
		self:_handle_login_response(data)
	end)
end

-- A Nakama error answer carries a code; a request that never reached the
-- server (refused, timed out, not JSON) has none.
function connection:_nakama_auth_failed(session)
	local message = session and (session.message or session.error) or 'no response'
	if type(message) == 'table' then
		message = message.message or 'error'
	end
	local answered = session ~= nil and session.code ~= nil
	local reason = answered and MPAPI.OfflineReason.OTHER or self:_no_answer_reason()
	self:_login_refused('Nakama auth failed: ', message, reason)
end

-- A refused Nakama login. A banned account's refusal ("Account banned ...",
-- see api/connection/moderation.lua) is shown to the player as a ban.
function connection:_login_refused(prefix, message, offline_reason)
	local moderation = MPAPI._internal.moderation
	local ban = moderation and moderation.account_ban_message(message)
	if ban and MPAPI.show_banned_notice then
		MPAPI.show_banned_notice('k_banned_title', ban)
	end
	set_state(self, STATES.DISCONNECTED, { error = prefix .. tostring(message), banned = ban, offline_reason = offline_reason })
end

-- The Steam ticket goes to Nakama as a custom login: Nakama's built-in Steam
-- check needs Balatro's publisher key, so the server's runtime hook checks
-- the ticket in vars.steam_ticket and replaces the placeholder id with
-- "steam:<steamid>".
function connection:_try_steam_auth()
	if not self.steam or not self.steam.available() then
		fail(self, MPAPI.OfflineReason.STEAM_NOT_RUNNING, 'Steam is not available')
		return
	end

	local ticket_data, ticket_err = self.steam.get_auth_ticket()
	if not ticket_data then
		fail(self, MPAPI.OfflineReason.STEAM_TICKET_FAILED, 'Steam ticket failed: ' .. tostring(ticket_err))
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

-- Dev only: log in as another player with a device login keyed by the
-- target (needs the server's ALLOW_DEVICE_AUTH). target is a table with one
-- of: playerId, steamId, discordId, steamName. Lets a second instance act as
-- a different account for multiplayer testing.
function connection:_try_impersonate_auth(target)
	set_state(self, STATES.AUTHENTICATING)
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

-- Logged in: open the socket (it carries the server's pushes) and go
-- CONNECTED.
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
			fail(self, self:_no_answer_reason(), 'Nakama socket failed: ' .. tostring(err))
			return
		end
		set_state(self, STATES.CONNECTED)
		-- The seat check waits for the mod report: a matchmade game only
		-- takes back a player whose report this session meets its standing
		-- (BalatroMultiplayerServer nakama/src/standing/rejoin.ts).
		local check_seat = self._check_nakama_lobby
		self._check_nakama_lobby = nil
		self:_report_mods(function()
			if check_seat then
				self:_check_nakama_lobby_seat()
			end
		end)
		-- The socket carries the launcher-integrity challenges
		-- (api/connection/integrity.lua), so they only start now.
		self:_nakama_rpc('launcher_session_start', {}, function(err)
			if err then
				MPAPI.sendWarnMessage('launcher_session_start failed: ' .. tostring(err))
			end
		end)
	end)
end

-- Entry point called by the UI / game to initiate a connection.
function connection:connect()
	if self.state ~= STATES.DISCONNECTED then
		fire(self, self.state, { error = 'Already ' .. self.state })
		return
	end

	if not self.steam or not self.steam.available() then
		fail(self, MPAPI.OfflineReason.STEAM_NOT_RUNNING, 'Steam is not available')
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
	local body = {}
	if chat_eligible ~= nil then
		body.chatEligible = chat_eligible and true or false
	end
	self:_nakama_rpc('tos_accept', body, function(err, data)
		if self.state ~= STATES.AUTHENTICATING then
			return
		end
		if err then
			fail(self, MPAPI.OfflineReason.OTHER, 'ToS acceptance failed: ' .. tostring(err))
			return
		end
		data.token = token
		self:_handle_auth_success(data)
	end)
end

-- Called by the UI when the user declines the ToS.
-- Disconnects fully; the prompt will appear again on the next connection attempt.
function connection:decline_tos()
	self._pending_tos_token = nil
	set_state(self, STATES.DISCONNECTED)
end

-- The session's mod report (api/connection/profile.lua); on_reported(), whatever the
-- answer, once the server has replied.
function connection:_report_mods(on_reported)
	local send = MPAPI._internal.send_installed_mods
	if not send then
		on_reported()
		return
	end
	send(function()
		on_reported()
	end)
end

-- A seat in a lobby survives a game restart; lobby_current finds it, and it
-- goes out as a second CONNECTED with reconnected_lobby. Once per login, and
-- not while already in a lobby.
function connection:_check_nakama_lobby_seat()
	local lobby = MPAPI._internal.lobby
	if not lobby or lobby.current then
		return
	end
	lobby.nakama_check_current(function(lobby_data)
		if lobby_data and self.state == STATES.CONNECTED and not lobby.current then
			fire(self, STATES.CONNECTED, { reconnected_lobby = lobby_data })
		end
	end)
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

-- Sends a launcher-integrity challenge result through the
-- launcher_challenge_answer RPC. `result` is whatever anticheat/launcher_channel.lua's
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

	self:_nakama_rpc('launcher_challenge_answer', body, function(err)
		if err then
			MPAPI.sendWarnMessage('launcher_challenge_answer failed: ' .. tostring(err))
		end
	end)
end

function connection:disconnect()
	if self.state == STATES.DISCONNECTED then
		return
	end

	if self.auth_ticket_handle and self.steam then
		self.steam.cancel_auth_ticket(self.auth_ticket_handle)
		self.auth_ticket_handle = nil
	end

	set_state(self, STATES.DISCONNECTED)
	if MPAPI.networking.nakama_lobby then
		MPAPI.networking.nakama_lobby.reset()
	end
	self.player_id = nil
	self.session_token = nil
	self.nakama_session = nil
end

MPAPI.networking.connection = connection
