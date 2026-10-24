-- Why the client is offline after a failed connection: a closed set, so the
-- main menu can show the player one short reason they can act on, never the
-- raw error text. A connection failure carries it as the `offline_reason`
-- field of its state-change context (networking/connection.lua).
MPAPI.OfflineReason = {
	OPENSSL_NOT_FOUND = 'openssl_not_found',
	STEAM_NOT_RUNNING = 'steam_not_running',
	STEAM_TICKET_FAILED = 'steam_ticket_failed',
	SERVER_UNREACHABLE = 'server_unreachable',
	OTHER = 'other',
}

-- The reason for a request that never got an answer from the server: over
-- TLS without OpenSSL nothing can reach it, otherwise the server is down or
-- out of reach.
function MPAPI.offline_reason_for_no_answer(secure, openssl_available)
	if secure and not openssl_available then
		return MPAPI.OfflineReason.OPENSSL_NOT_FOUND
	end
	return MPAPI.OfflineReason.SERVER_UNREACHABLE
end

-- The localization key of a reason's menu text.
function MPAPI.offline_reason_key(reason)
	return 'k_offline_' .. reason
end
