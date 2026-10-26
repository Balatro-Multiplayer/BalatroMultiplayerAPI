-- Why the client is offline after a failed connection: a closed set, so the
-- main menu can show the player one short reason they can act on. A
-- connection failure carries it as the `offline_reason` field of its
-- state-change context (networking/connection.lua), and a refusal from the
-- server also carries the server's own message as `server_message`.
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

-- The reason for a server that answered with a refusal: "Steam ticket failed"
-- when the error clearly names the Steam ticket, otherwise `other`.
function MPAPI.offline_reason_for_server_refusal(message)
	if type(message) == 'table' then
		message = message.message
	end
	if type(message) == 'string' and message:lower():find('steam ticket', 1, true) then
		return MPAPI.OfflineReason.STEAM_TICKET_FAILED
	end
	return MPAPI.OfflineReason.OTHER
end

-- The localization key of a reason's menu text.
function MPAPI.offline_reason_key(reason)
	return 'k_offline_' .. reason
end

-- The panel is narrow: the server's message is wrapped to fit.
local MESSAGE_WIDTH = 26
local MESSAGE_LINES = 3

-- The menu lines for a failed connection: the server's own message when it
-- refused for a reason with no text of its own (`other`), else the reason's
-- one line. Never the raw transport error.
function MPAPI.offline_reason_lines(reason, server_message)
	if reason == MPAPI.OfflineReason.OTHER and type(server_message) == 'string' and server_message:find('%S') then
		return MPAPI.wrap_words(server_message, MESSAGE_WIDTH, MESSAGE_LINES)
	end
	return { localize(MPAPI.offline_reason_key(reason)) }
end
