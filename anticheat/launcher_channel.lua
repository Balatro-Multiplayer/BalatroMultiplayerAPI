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

    IMPORTANT ordering note: MPAPI.on_launcher_supervision_lost,
    MPAPI.on_launcher_challenge_answered, and A.answer_challenge are all
    defined ABOVE the env-var early-return below, and thread/tx_channel/
    rx_channel are forward-declared as locals above that point too (Lua
    locals aren't hoisted - a function defined before a `local` of the same
    name would otherwise close over an unrelated global). This matters
    because the server issues a login challenge to every fresh MQTT
    connection regardless of game mode (see launcher-integrity.service.ts's
    handleClientConnected) - a Casual player, or anyone who started the game
    without BET at all, still needs A.answer_challenge to exist and safely
    self-refuse, not be nil.

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

-- Whether the *server* has confirmed our most recent challenge response was
-- actually correct - distinct from A.active/A.launcher_connected, which only
-- describe the local mod<->launcher socket and say nothing about whether the
-- server accepted what BET signed. Set by networking/connection.lua's
-- 'challenge' topic handler on a {type='verified'} message (see
-- launcher-integrity.service.ts's handleChallengeResponse) - never set
-- optimistically just because a response was sent. Starts false on every
-- fresh load (a new MQTT connection means a fresh login challenge is coming
-- regardless), and is the one flag safe for other mods to gate a Ranked
-- queue button on - see MPAPI.is_launcher_verified() in
-- api/connection/lifecycle.lua.
A.server_verified = false

-- Called only from networking/connection.lua's challenge-topic handler.
function A.mark_server_verified()
	A.server_verified = true
end

A._internal = A._internal or {}
A._internal.supervision_lost_callbacks = A._internal.supervision_lost_callbacks or {}
A._internal.challenge_answered_callbacks = A._internal.challenge_answered_callbacks or {}
-- Challenges relayed via A.answer_challenge() before this channel's own
-- handshake with the launcher has finished yet - flushed once the
-- 'authenticated' event lands (see A.update() below). In practice this list
-- holds at most one entry (the server only ever keeps one challenge
-- outstanding per player at a time - see launcher-integrity.service.ts's
-- issueChallenge), but it's a list rather than a single slot so a challenge
-- that's reissued (e.g. the first one timed out server-side) before the
-- handshake finishes doesn't get dropped.
A._internal.pending_challenges = A._internal.pending_challenges or {}

-- See this file's header comment on why these are forward-declared here
-- rather than where they're first assigned, further down.
local thread = nil
local tx_channel = nil
local rx_channel = nil

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

-- Registers fn(result) to run whenever a launcher-integrity challenge relayed
-- via A.answer_challenge() gets an answer - either from the launcher itself
-- (result = {challenge_id, signature, hardware_fingerprint}, the last field
-- only present for a login-kind challenge), or an immediate refusal when
-- there's no launcher to ask at all, or the launcher reported an error
-- (result = {challenge_id, refused = true}). Unlike
-- on_launcher_supervision_lost, there's no "fire immediately" case here - an
-- answer is always the result of one specific request, never a standing
-- condition. See networking/connection.lua for the one real consumer
-- (publishing the result to the server).
function MPAPI.on_launcher_challenge_answered(fn)
	A._internal.challenge_answered_callbacks[#A._internal.challenge_answered_callbacks + 1] = fn
end

local function run_challenge_answered_callbacks(result)
	for _, fn in ipairs(A._internal.challenge_answered_callbacks) do
		local ok, err = pcall(fn, result)
		if not ok then
			MPAPI.sendWarnMessage('on_launcher_challenge_answered callback error: ' .. tostring(err))
		end
	end
end

-- Relays a launcher-integrity challenge (issued by the server over MQTT -
-- see networking/connection.lua) to the launcher for it to sign, and reports
-- the result via MPAPI.on_launcher_challenge_answered(). This module never
-- computes a signature itself - it has no secret to compute one with - it's
-- pure relay in both directions.
--
-- Must be safely callable unconditionally, even when this channel is
-- entirely inactive (Casual, or the game wasn't started via BET at all) -
-- see this file's header comment on why that case matters here. A game with
-- no launcher to ask can never produce a valid answer by construction - this
-- fails fast with an explicit refusal instead of leaving the caller to wait
-- out the server's own challenge timeout.
function A.answer_challenge(challenge_id, kind, nonce, player_id)
	if not A.active then
		run_challenge_answered_callbacks({ challenge_id = challenge_id, refused = true })
		return
	end

	if A.launcher_connected then
		tx_channel:push({
			cmd = 'answer_challenge',
			challenge_id = challenge_id,
			kind = kind,
			nonce = nonce,
			player_id = player_id,
		})
	else
		A._internal.pending_challenges[#A._internal.pending_challenges + 1] = {
			challenge_id = challenge_id,
			kind = kind,
			nonce = nonce,
			player_id = player_id,
		}
	end
end

local port = os.getenv('BET_RANKED_SUPERVISOR_PORT')
local secret_hex = os.getenv('BET_RANKED_SUPERVISOR_SECRET')

if not port or not secret_hex or port == '' or secret_hex == '' then
	-- Not launched via BET in Ranked mode - nothing more to do. A.active
	-- stays false; no thread is ever spawned. A.answer_challenge above
	-- already handles this case (immediate refusal) regardless.
	return A
end

A.active = true

local function start_thread()
	tx_channel = love.thread.newChannel()
	rx_channel = love.thread.newChannel()

	local thread_path = MPAPI.path .. '/anticheat/launcher_thread.lua'
	local file_content = assert(NFS.read(thread_path), 'Failed to read ' .. thread_path)
	local file_data = love.filesystem.newFileData(file_content, 'launcher_thread.lua')
	thread = love.thread.newThread(file_data)
	thread:start(tx_channel, rx_channel)

	-- The background thread's own require('anticheat.crypto')/
	-- require('openssl_ffi') can't actually resolve those files when this
	-- mod is deployed as a zip (the common case - see
	-- lib/thread_preload.lua for the full root-cause writeup): pkg_path
	-- below still points into Steamodded's virtual zip mount, which only
	-- the main thread's require() can read through. Pre-read the actual
	-- source here (this thread's NFS.read() works fine) and hand it over
	-- the channel so launcher_thread.lua can register it into its own
	-- package.preload before requiring it - this is why
	-- 'authentication failed'/'OpenSSL FFI not available in launcher
	-- thread' fired on every single Ranked launch until this fix, not
	-- just occasionally.
	--
	-- Loaded via MPAPI.load_mpapi_file (not require) for the same reason
	-- e72d5c4 fixed lib/debugplus/console.lua and ui.lua: on the MAIN
	-- thread require() is resolved by Lua's stock package.path searcher,
	-- which formats each package.path template as a plain OS file path
	-- and probes it with io.open-equivalent calls - that never actually
	-- reaches into a zip Steamodded has mounted through LÖVE's PhysFS-
	-- backed virtual filesystem, real single-slash path or not (confirmed
	-- live: this require('thread_preload') failed with "not found" even
	-- after ruling out the dotted-module/backslash-substitution case
	-- e72d5c4 hit, and even though package.path had the correct
	-- MPAPI.path .. '/lib/?.lua' entry from core.lua by this point - the
	-- searcher just can't read through the mount at all). NFS.read() (via
	-- MPAPI.load_mpapi_file -> SMODS.load_file) is the one file-loading
	-- path proven to work whether the mod is a folder or a zip - it's
	-- what every other MPAPI.load_mpapi_file/_dir call in core.lua
	-- already relies on.
	local thread_preload = MPAPI.load_mpapi_file('lib/thread_preload.lua')
	local preload = thread_preload.read_single_module('anticheat/crypto.lua', 'anticheat.crypto')
	for name, source in pairs(thread_preload.read_single_module('networking/openssl_ffi.lua', 'openssl_ffi')) do
		preload[name] = source
	end

	tx_channel:push({
		port = tonumber(port),
		secret_hex = secret_hex,
		pkg_path = package.path or '',
		pkg_cpath = package.cpath or '',
	})
	-- Sent as its own message, not nested inside the table above -
	-- love.thread Channels only support flat tables (no nested tables)
	-- for automatic serialization; preload's own values are plain
	-- strings so it's flat on its own, but nesting it inside the setup
	-- table above would not be.
	tx_channel:push(preload)
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
			if #A._internal.pending_challenges > 0 then
				for _, pending in ipairs(A._internal.pending_challenges) do
					tx_channel:push({
						cmd = 'answer_challenge',
						challenge_id = pending.challenge_id,
						kind = pending.kind,
						nonce = pending.nonce,
						player_id = pending.player_id,
					})
				end
				A._internal.pending_challenges = {}
			end
		elseif event.type == 'supervision_lost' then
			A.launcher_supervision_lost = true
			A.launcher_supervision_lost_at = os.time()
			MPAPI.sendWarnMessage('Lost contact with the BET launcher during a Ranked run.')
			run_supervision_lost_callbacks()
			-- Repaint the main-menu RANKED badge (ui/main_menu.lua) so a
			-- supervision drop is visible without the player having to
			-- close/reopen the account panel. nil-checked: the badge only
			-- ever gets built once account_button itself has loaded, and
			-- this event can in principle race that on startup.
			if MPAPI.account_button then
				MPAPI.account_button:update()
			end
		elseif event.type == 'supervision_restored' then
			A.launcher_supervision_lost = false
			A.launcher_supervision_lost_at = nil
			MPAPI.sendDebugMessage('Ranked anti-cheat supervision channel restored.')
			if MPAPI.account_button then
				MPAPI.account_button:update()
			end
		elseif event.type == 'fatal_error' then
			-- The launcher already enforces its own handshake timeout (it
			-- kills the game process if the mod never authenticates - see
			-- rankedsupervisor.h) - this side doesn't need its own retry
			-- loop or self-destructive fallback, just to stop trying and
			-- log why. Any challenges still queued for this now-dead channel
			-- can only ever be answered with a refusal.
			MPAPI.sendWarnMessage('Ranked anti-cheat supervision channel failed: ' .. tostring(event.message))
			A.launcher_connected = false
			if #A._internal.pending_challenges > 0 then
				for _, pending in ipairs(A._internal.pending_challenges) do
					run_challenge_answered_callbacks({ challenge_id = pending.challenge_id, refused = true })
				end
				A._internal.pending_challenges = {}
			end
		elseif event.type == 'challenge_answered' then
			if event.error then
				run_challenge_answered_callbacks({ challenge_id = event.challenge_id, refused = true })
			else
				run_challenge_answered_callbacks({
					challenge_id = event.challenge_id,
					signature = event.signature,
					hardware_fingerprint = event.hardware_fingerprint,
				})
			end
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
