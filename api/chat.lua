MPAPI.chat = {}

local COLOUR_INCOMING = { 0, 1, 1 } -- cyan  — other players
local COLOUR_OWN = { 0.65, 0.36, 1 } -- BMP purple — own messages
local COLOUR_SYSTEM = { 1, 1, 0 } -- yellow — system notices

local console = MPAPI.load_mpapi_file('lib/debugplus/console.lua')
local dp_compat = MPAPI.load_mpapi_file('compatibility/debugplus.lua')

local using_dp = false

-- Current lobby reference and whether chat is actively subscribed in it
local _current_lobby = nil
local _lobby_chat_active = false
local _chat_topic = nil

-- Moderation UX state (reset on cleanup):
--   _muted = { [player_id] = true } — client-side mutes; muted senders are
--     dropped from the local display. The mute ACTION is local; we also send an
--     aggregate signal so moderation can auto-review a widely-muted player.
local _muted = {}

-----------------------------
-- MESSAGE DISPLAY
-----------------------------

function MPAPI.chat.addMessage(str, colour)
	if using_dp then
		dp_compat.addMessage(str, colour)
	else
		console.addMessage(str, colour)
	end
end

-----------------------------
-- SHARED HELPERS
-----------------------------

local function make_not_enabled_cb()
	return function(_)
		if MPAPI.connection_state.chat_enabled then
			MPAPI.chat.addMessage(localize('k_chat_lobby_only'), COLOUR_SYSTEM)
		else
			MPAPI.chat.addMessage(localize('k_chat_not_enabled'), COLOUR_SYSTEM)
		end
	end
end

local function make_publish_fn(lobby)
	return function(text)
		if not MPAPI.config.chat_enabled then
			MPAPI.chat.addMessage(localize('k_chat_client_disabled'), COLOUR_SYSTEM)
			return
		end
		-- The server rejects whitespace-only messages; don't echo them either.
		if text:match('^%s*$') then
			return
		end
		-- Optimistic local echo: show the sender their own message instantly
		-- instead of waiting ~1s for the moderated MQTT echo. Recipients are
		-- unaffected — they still only ever receive the moderated message.
		-- subscribe_chat drops our own MQTT echo so this doesn't double-render.
		local own_name = MPAPI.chat._own_name or localize('k_you')
		MPAPI.chat.addMessage(own_name .. ': ' .. text, COLOUR_OWN)
		MPAPI._internal.send_chat_message(lobby.code, text, function(err, data)
			if err then
				-- The message above never reached anyone; say so with the
				-- server's reason (moderated / rate-limited / unavailable).
				MPAPI.chat.addMessage(localize('k_chat_not_sent') .. ' ' .. tostring(err), COLOUR_SYSTEM)
			elseif data and type(data.publishText) == 'string' and data.publishText ~= text then
				-- Moderation rewrote the message; the echo above showed the raw
				-- form, so tell the sender what other players actually got.
				MPAPI.chat.addMessage(localize('k_chat_sent_as') .. ' ' .. data.publishText, COLOUR_SYSTEM)
			end
		end)
	end
end

local function subscribe_chat(lobby)
	_chat_topic = lobby._mqtt:lobby_topic(lobby.code, 'chat/+')
	lobby._mqtt:subscribe(_chat_topic, 1, function(topic, payload)
		local sender_id = topic:match('/chat/([^/]+)$')

		local ok, data = pcall(MPAPI.json_decode, payload)
		if not ok or type(data) ~= 'table' or type(data.message) ~= 'string' then
			return
		end

		-- Own messages already rendered optimistically at send time
		-- (make_publish_fn); drop the MQTT echo so they don't double-render.
		if sender_id == lobby.player_id then
			return
		end

		-- Locally muted senders never render.
		if _muted[sender_id] then
			return
		end

		local name = data.displayName or sender_id
		MPAPI.chat.addMessage(name .. ': ' .. data.message, COLOUR_INCOMING)
	end)
end

local function unsubscribe_chat()
	if _chat_topic and _current_lobby then
		_current_lobby._mqtt:unsubscribe(_chat_topic)
	end
	_chat_topic = nil
end

-----------------------------
-- MODERATION ACTIONS
-----------------------------

-- Mute player_id for this session: local drop + best-effort aggregate signal.
-- Used by the report overlay's MUTE button. (Slash commands were removed —
-- all moderation actions go through UI surfaces: player cards, pause menu,
-- post-match screen.)
function MPAPI.chat.mute_player(player_id, name)
	_muted[player_id] = true
	if _current_lobby then
		-- Best-effort aggregate signal; the local mute above stands regardless.
		MPAPI._internal.mute_signal(_current_lobby.code, player_id, function() end)
	end
	MPAPI.chat.addMessage(localize('k_chat_muted') .. ' ' .. name, COLOUR_SYSTEM)
end

-- Wire up send callback + subscribe for the current lobby.
-- Safe to call mid-session (e.g. after enabling chat while already in a lobby).
-- No-ops if already active or conditions aren't met.
local function activate_lobby_chat(announce)
	if _lobby_chat_active then return end
	local lobby = _current_lobby
	if not lobby then return end
	if not MPAPI.connection_state.chat_enabled then return end

	local publish = make_publish_fn(lobby)

	if using_dp then
		dp_compat.send_fn = publish
	else
		MPAPI.chat._send_fn = publish
		console.setSendCallback(publish)
	end

	subscribe_chat(lobby)
	_lobby_chat_active = true

	if announce then
		if using_dp then
			MPAPI.chat.addMessage(localize('k_chat_ready_dp'), COLOUR_SYSTEM)
		else
			MPAPI.chat.addMessage(localize('k_chat_ready'), COLOUR_SYSTEM)
		end
	end
end

-- Called externally (e.g. from chat_enable_overlay) when chat is enabled mid-session.
function MPAPI.chat.on_chat_enabled()
	activate_lobby_chat(true)
end

-- Called when the local client-side chat_enabled config toggle changes.
function MPAPI.chat.on_config_changed(enabled)
	if enabled then
		-- Re-subscribe if we're in a lobby and server has verified chat
		if _lobby_chat_active then return end
		activate_lobby_chat(false)
	else
		unsubscribe_chat()
		_lobby_chat_active = false
		-- Reset send callback so sending is blocked
		if not using_dp then
			console.setSendCallback(make_not_enabled_cb())
		else
			dp_compat.send_fn = nil
		end
	end
end

-----------------------------
-- STARTUP: detect DebugPlus once after all mods have loaded
-----------------------------

G.E_MANAGER:add_event(Event({
	blockable = false,
	blocking = false,
	func = function()
		using_dp = dp_compat.init()

		if using_dp then
			MPAPI.chat.addMessage(localize('k_chat_dp_compat_info'), COLOUR_SYSTEM)
		else
			-- DP absent: hook bundled console into the draw loop
			MPAPI.chat.doRender = console.doConsoleRender
			MPAPI.chat.isOpen = console.isOpen
			console.setSendCallback(make_not_enabled_cb())
		end
		return true
	end,
}))

-----------------------------
-- LOBBY LIFECYCLE
-----------------------------

function MPAPI.chat.init(lobby)
	_current_lobby = lobby
	_lobby_chat_active = false

	local me = lobby._players[lobby.player_id]
	MPAPI.chat._own_name = (me and me.displayName) or localize('k_you')

	activate_lobby_chat(true)
end

function MPAPI.chat.cleanup()
	MPAPI.chat._send_fn = nil
	MPAPI.chat._own_name = nil
	_chat_topic = nil
	_current_lobby = nil
	_lobby_chat_active = false
	_muted = {}
	if using_dp then
		dp_compat.send_fn = nil
	else
		console.setSendCallback(make_not_enabled_cb())
	end
end
