-- Dev overrides: This file (and the dev/ directory) is stripped from release builds by CI.
local connection = MPAPI.networking.connection

-- Logs in via an ephemeral dev/temp account (random in-memory player id, not
-- persisted to the DB). A temp account can never queue matchmaking or appear on the
-- leaderboard (no players row), so this is commented out to fall back to real Steam
-- auth. Uncomment to use a throwaway dev account instead.
-- function connection._do_auth(self)
-- 	self:_try_dev_auth()
-- end

-- Impersonation: log in as an EXISTING player (real players row), so it can queue
-- matchmaking and appear on the leaderboard. This lets a second game instance act as
-- a different real account without a second Steam login -- useful for testing
-- matchmaking locally. Enable per-instance by setting one of these env vars before
-- launching that instance (the other instance, with neither set, uses real Steam):
--   BMP_IMPERSONATE_ID=<players.id uuid>
--   BMP_IMPERSONATE_NAME=<steamName>      e.g. a seeded "Runner001"
local imp_id = os.getenv('BMP_IMPERSONATE_ID')
local imp_name = os.getenv('BMP_IMPERSONATE_NAME')
if imp_id or imp_name then
	local target = imp_id and { playerId = imp_id } or { steamName = imp_name }
	function connection._do_auth(self)
		self:_try_impersonate_auth(target)
	end
	MPAPI.sendDebugMessage('Dev impersonation auth enabled for ' .. tostring(imp_id or imp_name))
end

-- Ranked anti-cheat, local-supervision half: api/matchmaking/api.lua's
-- MPAPI.matchmaking.queue() refuses any ranked=true queue attempt unless
-- MPAPI.anticheat.active/launcher_connected are true (anticheat/
-- launcher_channel.lua) -- normally only set by a real BET launch via
-- BET_RANKED_SUPERVISOR_PORT/_SECRET, since that's the local IPC socket a
-- real launcher keeps open to this game process. A ClaudeControl-driven
-- instance never has one. This flag forces those fields true so a queue
-- attempt actually reaches the server instead of refusing locally.
--
-- This is only one half of "queue and play a real ranked match" -- the
-- server has its own, independent launcher-integrity check over MQTT
-- (server-side login challenge/response) that this doesn't touch at all;
-- pair with the server's own DEV_AUTO_VERIFY_LAUNCHER env flag
-- (BalatroMultiplayerServer's launcher-integrity.service.ts) for that half.
if os.getenv('BMP_DEV_SKIP_RANKED_ANTICHEAT') then
	MPAPI.anticheat.active = true
	MPAPI.anticheat.launcher_connected = true
	MPAPI.anticheat.launcher_supervision_lost = false
	MPAPI.sendDebugMessage('Dev bypass: local ranked anti-cheat supervision forced active.')
end

MPAPI.sendDebugMessage('Dev auth overrides applied')
