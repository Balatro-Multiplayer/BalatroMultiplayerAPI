-- Launcher integrity pushed over the Nakama socket (config nakama_only): the
-- counterpart of the MQTT player/{id}/challenge topic
-- (networking/connection.lua). The API still runs the challenges
-- (launcher-integrity.service.ts); Nakama passes them on as CHALLENGE
-- notifications and the API's verdicts as INTEGRITY ones
-- (BalatroMultiplayerServer nakama/src/integrity.ts). Answers go back
-- through connection:_publish_challenge_response.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

local function on_challenge(msg)
	if msg.type ~= 'issued' or not msg.challengeId or not C.connection then
		return
	end
	C.connection:_answer_launcher_challenge(msg.challengeId, msg.kind, msg.nonce)
end

-- {verified, reason, message}. Failing is the normal outcome for any
-- non-BET launch, so it stays silent, as on MQTT; it only closes ranked.
local function on_integrity(msg)
	local A = MPAPI.anticheat
	if not A then
		return
	end
	if msg.verified then
		A.mark_server_verified()
	else
		A.server_verified = false
	end
end

do
	local notify = MPAPI.networking.nakama_notify
	if notify then
		notify.on(notify.Code.CHALLENGE, on_challenge)
		notify.on(notify.Code.INTEGRITY, on_integrity)
	end
end
