-- Per-mod "one of my lobbies is gone" hook. L.cleanup is the one place every
-- way out of a lobby passes through (leave, kick, ban, host close, a lost
-- socket, a refused create/join), so a mod that keeps its own per-lobby state
-- can reset it here instead of on each exit path it happens to know about.
-- A group home lobby stepped out of for its public game is not gone: the
-- session carries on in the public lobby, and that one's own end is.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

L.gone_handlers = L.gone_handlers or {}

-- handler(lobby) runs once whenever a lobby of `mod_id` is torn down, local
-- (practice, playback) lobbies included. Only that mod's lobbies reach it.
function MPAPI.on_lobby_gone(mod_id, handler)
	L.gone_handlers[mod_id] = L.gone_handlers[mod_id] or {}
	table.insert(L.gone_handlers[mod_id], handler)
end

function L.notify_lobby_gone(lobby)
	if lobby._group_stepped_out then
		return
	end
	for _, handler in ipairs(L.gone_handlers[lobby.mod_id] or {}) do
		local ok, err = pcall(handler, lobby)
		if not ok then
			MPAPI.sendWarnMessage('on_lobby_gone handler error (' .. tostring(lobby.mod_id) .. '): ' .. tostring(err))
		end
	end
end
