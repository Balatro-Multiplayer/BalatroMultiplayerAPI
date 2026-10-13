-- Dev overrides: this file (and the dev/ directory) is stripped from release
-- builds by CI (.github/workflows/strip-dev.yml).
local C = MPAPI._internal.conn
local connection = MPAPI.networking.connection

-- Dev builds talk to the local stack (BalatroMultiplayerServer's
-- docker-compose: Nakama on 7350, plain HTTP, the stock server key) unless
-- BMP_SERVER_HOST names another one. The mod config's server_* keys still
-- take precedence over these.
local host = os.getenv('BMP_SERVER_HOST')
if host then
	C.SERVER_DEFAULTS.host = host
	C.SERVER_DEFAULTS.port = tonumber(os.getenv('BMP_SERVER_PORT')) or C.SERVER_DEFAULTS.port
else
	C.SERVER_DEFAULTS.host = '127.0.0.1'
	C.SERVER_DEFAULTS.port = 7350
	C.SERVER_DEFAULTS.secure = false
	C.SERVER_DEFAULTS.server_key = 'defaultkey'
	C.SERVER_DEFAULTS.web_url = 'http://127.0.0.1:3000'
end

-- Impersonation: log in as another account with a Nakama device login (needs
-- the server's ALLOW_DEVICE_AUTH), so a second game instance can act as a
-- different player without a second Steam login. Set one of these before
-- launching that instance (an instance with neither uses real Steam):
--   BMP_IMPERSONATE_ID=<id>
--   BMP_IMPERSONATE_NAME=<steamName>
local imp_id = os.getenv('BMP_IMPERSONATE_ID')
local imp_name = os.getenv('BMP_IMPERSONATE_NAME')
if imp_id or imp_name then
	local target = imp_id and { playerId = imp_id } or { steamName = imp_name }
	function connection._do_auth(self)
		self:_try_impersonate_auth(target)
	end
	MPAPI.sendDebugMessage('Dev impersonation auth enabled for ' .. tostring(imp_id or imp_name))
end

-- Ranked anti-cheat, local-supervision half: MPAPI.matchmaking.queue()
-- refuses a ranked queue unless MPAPI.anticheat.active/launcher_connected
-- are true, which only a real BET launch sets. This forces them so a
-- ClaudeControl-driven instance can queue ranked. The server's own
-- launcher-integrity check is separate: pair with its DEV_AUTO_VERIFY_LAUNCHER.
if os.getenv('BMP_DEV_SKIP_RANKED_ANTICHEAT') then
	MPAPI.anticheat.active = true
	MPAPI.anticheat.launcher_connected = true
	MPAPI.anticheat.launcher_supervision_lost = false
	MPAPI.sendDebugMessage('Dev bypass: local ranked anti-cheat supervision forced active.')
end

MPAPI.sendDebugMessage('Dev overrides applied')
