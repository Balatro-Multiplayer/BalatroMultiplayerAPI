--[[
    Ranked-mode launcher<->mod supervision channel - main-thread side.

    Entirely gated on two env vars BET only ever sets for a Ranked launch
    (BET_RANKED_SUPERVISOR_PORT / BET_RANKED_SUPERVISOR_SECRET, read once
    via os.getenv at load time, same one-shot-env-var-at-startup
    precedent as dev/init.lua's BMP_IMPERSONATE_ID). Their absence -
    Casual launches, or the game started manually outside BET entirely -
    means this whole module stays completely inert: no thread, no
    socket, MPAPI.anticheat.active stays false. That's the mechanism that
    makes Casual a zero-behavior-change no-op, not a special case handled
    here.

    The actual network/crypto work happens on anticheat/launcher_thread.lua,
    a dedicated love.thread, following networking/mqtt_client.lua's own
    thread-spawn/tx_channel/rx_channel convention exactly (see that file).
]]

MPAPI.anticheat = MPAPI.anticheat or {}
local A = MPAPI.anticheat

A.active = false
A.launcher_connected = false
A.launcher_supervision_lost = false
A.launcher_supervision_lost_at = nil

A._internal = A._internal or {}
A._internal.supervision_lost_callbacks = A._internal.supervision_lost_callbacks or {}

-- Registers fn to run whenever the mod detects the launcher's heartbeat
-- has gone silent mid-Ranked-run (see anticheat/launcher_thread.lua's
-- watchdog). By policy this never interrupts gameplay itself - it's a
-- flag-and-continue signal for a future consumer (e.g. BalatroMultiplayerPvP's
-- replay/hash recorder) to fold into whatever it reports, not something
-- this repo acts on directly. Fires immediately (synchronously) if
-- supervision was already lost by the time this is called, same
-- "run now if the condition already holds" convention as MPAPI.on_loaded.
function MPAPI.on_launcher_supervision_lost(fn)
	if A.launcher_supervision_lost then
		local ok, err = pcall(fn)
		if not ok then
			MPAPI.sendWarnMessage('on_launcher_supervision_lost callback error: ' .. tostring(err))
		end
		return
	end
	A._internal.supervision_lost_callbacks[#A._internal.supervision_lost_callbacks + 1] = fn
end

local function run_supervision_lost_callbacks()
	for _, fn in ipairs(A._internal.supervision_lost_callbacks) do
		local ok, err = pcall(fn)
		if not ok then
			MPAPI.sendWarnMessage('on_launcher_supervision_lost callback error: ' .. tostring(err))
		end
	end
end

-- Set by notify_session() when it arrives before A.launcher_connected is
-- true yet (the mod's own server login can finish before or after this
-- channel's handshake with the launcher - no guaranteed ordering) - flushed
-- once the 'authenticated' event below actually lands.
A._internal.pending_session = nil

local port = os.getenv('BET_RANKED_SUPERVISOR_PORT')
local secret_hex = os.getenv('BET_RANKED_SUPERVISOR_SECRET')

if not port or not secret_hex or port == '' or secret_hex == '' then
	-- Not launched via BET in Ranked mode - nothing more to do. A.active
	-- stays false; no thread is ever spawned.
	return A
end

A.active = true

local thread = nil
local tx_channel = nil
local rx_channel = nil

local function start_thread()
	tx_channel = love.thread.newChannel()
	rx_channel = love.thread.newChannel()

	local thread_path = MPAPI.path .. '/anticheat/launcher_thread.lua'
	local file_content = assert(NFS.read(thread_path), 'Failed to read ' .. thread_path)
	local file_data = love.filesystem.newFileData(file_content, 'launcher_thread.lua')
	thread = love.thread.newThread(file_data)
	thread:start(tx_channel, rx_channel)

	tx_channel:push({
		port = tonumber(port),
		secret_hex = secret_hex,
		pkg_path = package.path or '',
		pkg_cpath = package.cpath or '',
	})
end

-- Drains rx_channel and reacts to events pushed by launcher_thread.lua.
-- Called from MPAPI.update() (see core.lua's chain-wrap of it) - the same
-- "run every frame" hook networking/api/connection/lifecycle.lua already
-- uses for the MQTT client's own update().
function A.update()
	if not rx_channel then
		return
	end

	while true do
		local event = rx_channel:pop()
		if not event then
			break
		end

		if event.type == 'authenticated' then
			A.launcher_connected = true
			MPAPI.sendDebugMessage('Ranked anti-cheat supervision channel authenticated.')
			if A._internal.pending_session then
				tx_channel:push({
					cmd = 'send_session_token',
					token = A._internal.pending_session.token,
					player_id = A._internal.pending_session.player_id,
				})
				A._internal.pending_session = nil
			end
		elseif event.type == 'supervision_lost' then
			A.launcher_supervision_lost = true
			A.launcher_supervision_lost_at = os.time()
			MPAPI.sendWarnMessage('Lost contact with the BET launcher during a Ranked run.')
			run_supervision_lost_callbacks()
		elseif event.type == 'supervision_restored' then
			A.launcher_supervision_lost = false
			A.launcher_supervision_lost_at = nil
			MPAPI.sendDebugMessage('Ranked anti-cheat supervision channel restored.')
		elseif event.type == 'fatal_error' then
			-- The launcher already enforces its own handshake timeout (it
			-- kills the game process if the mod never authenticates - see
			-- rankedsupervisor.h) - this side doesn't need its own retry
			-- loop or self-destructive fallback, just to stop trying and
			-- log why.
			MPAPI.sendWarnMessage('Ranked anti-cheat supervision channel failed: ' .. tostring(event.message))
			A.launcher_connected = false
		elseif event.type == 'log' then
			MPAPI.sendDebugMessage(tostring(event.message))
		end
	end

	if thread then
		local err = thread:getError()
		if err then
			MPAPI.sendWarnMessage('Ranked anti-cheat supervision thread crashed: ' .. tostring(err))
			thread = nil
			A.launcher_connected = false
		end
	end
end

-- Hands the mod's own server session (token + player id) to the launcher
-- over this already-authenticated channel, once the mod itself reaches
-- MPAPI.ConnectionState.CONNECTED (see api/connection/lifecycle.lua's
-- connection_on_state_change). The launcher uses this to open its own
-- direct connection to the server as the same player
-- (LauncherIntegrityClient) rather than independently re-authenticating via
-- Steam - one Steam auth ticket per Ranked run instead of two.
--
-- A no-op if this channel isn't active at all (Casual, or the game started
-- outside BET - A.active stays false, see the top of this file). If it IS
-- active but hasn't finished its own handshake with the launcher yet, the
-- session is queued (pending_session above) and flushed as soon as the
-- 'authenticated' event arrives - there's no guaranteed ordering between
-- "mod logs into the game server" and "this channel's own handshake
-- completes".
function A.notify_session(token, player_id)
	if not A.active then
		return
	end
	if not token or token == '' or not player_id or player_id == '' then
		return
	end

	if A.launcher_connected then
		tx_channel:push({ cmd = 'send_session_token', token = token, player_id = tostring(player_id) })
	else
		A._internal.pending_session = { token = token, player_id = tostring(player_id) }
	end
end

-- Chain onto MPAPI.update, same "run every frame" wrap pattern
-- api/connection/lifecycle.lua uses for the MQTT client's own update() -
-- MPAPI.update is called once per frame via the no_delete Event core.lua
-- registers with G.E_MANAGER.
local MPAPI_update_ref = MPAPI.update
MPAPI.update = function()
	A.update()
	MPAPI_update_ref()
end

start_thread()

return A
