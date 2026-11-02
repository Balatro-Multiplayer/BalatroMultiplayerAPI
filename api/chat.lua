MPAPI.chat = {}

local COLOUR_INCOMING = { 0, 1, 1 } -- cyan  — other players
local COLOUR_OWN = { 0.65, 0.36, 1 } -- BMP purple — own messages
local COLOUR_SYSTEM = { 1, 1, 0 } -- yellow — system notices

local console = MPAPI.load_mpapi_file('lib/debugplus/console.lua')
local dp_compat = MPAPI.load_mpapi_file('compatibility/debugplus.lua')

local using_dp = false

-- Current lobby reference and whether chat is active in it
local _current_lobby = nil
local _lobby_chat_active = false

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
	return function(text)
		if text:sub(1, 1) == '/' then
			MPAPI.chat.addMessage(localize('k_chat_unknown_command') .. ': ' .. text, COLOUR_SYSTEM)
			return
		end
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
		-- The server moderates it and sends it back to everyone, us included.
		MPAPI.networking.nakama_lobby.rpc('chat_send', { message = text }, function(err, _)
			if err then
				MPAPI.chat.addMessage('[!] ' .. tostring(err), COLOUR_SYSTEM)
			end
		end)
	end
end

-- Shows one chat line from `sender_id` (a muted sender's is dropped): a
-- lobby's CHAT op (api/lobby/nakama.lua).
function MPAPI.chat.on_message(lobby, sender_id, display_name, message)
	-- Checked before anything else, per the design doc: a muted sender's
	-- message is silently dropped.
	if MPAPI.connection_state.mute_list[sender_id] then
		return
	end
	if type(message) ~= 'string' then
		return
	end
	local name = display_name or sender_id
	local colour = (sender_id == lobby.player_id) and COLOUR_OWN or COLOUR_INCOMING
	MPAPI.chat.addMessage(name .. ': ' .. message, colour)
end

-- Wire up the send callback for the current lobby.
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
		console.setSendCallback(function(text)
			if text:sub(1, 1) == '/' then
				MPAPI.chat.addMessage(localize('k_chat_unknown_command') .. ': ' .. text, COLOUR_SYSTEM)
				return
			end
			publish(text)
		end)
	end

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
		-- Reactivate if we are in a lobby and the server has verified chat
		if _lobby_chat_active then return end
		activate_lobby_chat(false)
	else
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

function MPAPI.chat.cleanup(lobby)
	if lobby and _current_lobby and lobby ~= _current_lobby then
		return
	end
	MPAPI.chat._send_fn = nil
	MPAPI.chat._own_name = nil
	_current_lobby = nil
	_lobby_chat_active = false
	if using_dp then
		dp_compat.send_fn = nil
	else
		console.setSendCallback(make_not_enabled_cb())
	end
end
