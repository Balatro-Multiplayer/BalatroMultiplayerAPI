-- Contract test for a server QUEUE_CANCELLED.
local T = dofile('tests/support.lua')
local check = T.check

-- It names the queue by the bare board name (no 'ranked:' prefix, like the ticket's mode), so
-- it must end the handle of a ranked queue whose game_mode is 'ranked:<board>'.
T.part(function()
	MPAPI = { _internal = {}, matchmaking = {}, networking = {} }
	dofile('domain/standing.lua')
	dofile('api/matchmaking/state.lua')
	dofile('api/connection/moderation.lua')
	local mm = MPAPI._internal.mm
	local Moderation = MPAPI._internal.moderation

	local ranked = { mod_id = 'MultiplayerPvP', game_mode = 'ranked:pvp_ranked_balanced' }
	local casual = { mod_id = 'MultiplayerPvP', game_mode = 'pvp_casual' }
	local other = { mod_id = 'MultiplayerSPDRN', game_mode = 'pvp_ranked_balanced' }
	mm.handles = { casual, other, ranked }

	check(mm.find_handle_by_mode('MultiplayerPvP', 'pvp_ranked_balanced') == ranked, 'a bare board name finds the ranked handle')
	check(mm.find_handle_by_mode('MultiplayerPvP', 'pvp_casual') == casual, 'a casual handle is found by its mode')
	check(mm.find_handle_by_mode('MultiplayerPvP', 'ranked:pvp_ranked_balanced') == ranked, 'the prefixed key still finds it')
	check(mm.find_handle_by_mode('MultiplayerSPDRN', 'pvp_ranked_balanced') == other, 'the mod id is part of the match')
	check(mm.find_handle_by_mode('MultiplayerPvP', 'nope') == nil, 'an unknown mode finds nothing')

	local refusal = Moderation.standing_refusal_of({ code = 'version_mismatch' })
	check(refusal and refusal.code == MPAPI.QueueRefusalCode.VERSION_MISMATCH, 'version_mismatch is a known refusal code')
end)

-- Each reason the server can send maps to its own error kind, removes the ranked handle and
-- shows the notice.
T.part(function()
	local handlers = {}
	MPAPI = { _internal = {}, matchmaking = {}, networking = { nakama_notify = {
		Code = { BANNED = 1, QUEUE_CANCELLED = 103 },
		on = function(code, fn) handlers[code] = fn end,
	}, nakama_lobby = { unqueue = function() end } },
		sendDebugMessage = function() end }
	dofile('domain/error_kind.lua')
	dofile('domain/matchmaking_event.lua')
	dofile('domain/standing.lua')
	dofile('domain/result.lua')
	dofile('api/matchmaking/state.lua')
	dofile('api/matchmaking/dispatch.lua')
	dofile('api/connection/moderation.lua')
	local mm = MPAPI._internal.mm
	local K = MPAPI.ErrorKind

	local shown = {}
	MPAPI.show_ranked_queue_cancelled_notice = function(r) shown[#shown + 1] = r end

	local function new_handle()
		local h = { mod_id = 'MultiplayerPvP', game_mode = 'ranked:pvp_ranked_balanced', _nakama_ranked = true, fired = {} }
		function h:_fire(ev, err) self.fired[#self.fired + 1] = { ev = ev, err = err } end
		return h
	end
	mm.remove_handle = function(h)
		for i, x in ipairs(mm.handles) do if x == h then table.remove(mm.handles, i) break end end
	end

	local function cancel(reason, extra)
		local h = new_handle()
		mm.handles = { h }
		shown = {}
		local msg = { reason = reason, requeue = false }
		for k, v in pairs(extra or {}) do msg[k] = v end
		handlers[103](msg)
		return h
	end

	-- reason -> error kind, every reason the server can send
	local cases = {
		{ 'launcher_outdated', K.RANKED_LAUNCHER_OUTDATED },
		{ 'mods_outdated', K.RANKED_MODS_OUTDATED },
		{ 'verification_timeout', K.RANKED_VERIFICATION_TIMEOUT },
		{ 'something_unknown', K.RANKED_MODS_OUTDATED }, -- falls back as before
	}
	for _, c in ipairs(cases) do
		local h = cancel(c[1])
		check(#h.fired == 1 and h.fired[1].ev == 'error', c[1] .. ' fires one error')
		check(h.fired[1].err.kind == c[2], c[1] .. ' maps to ' .. c[2] .. ' got ' .. tostring(h.fired[1].err.kind))
		check(#mm.handles == 0, c[1] .. ' removes the handle')
		check(#shown == 1 and shown[1] == c[1], c[1] .. ' shows the notice with the same reason')
	end
	check(K.RANKED_VERIFICATION_TIMEOUT == 'ranked_verification_timeout', 'wire string of the new kind')
	check(K.RANKED_VERIFICATION_TIMEOUT ~= K.RANKED_MODS_OUTDATED and K.RANKED_VERIFICATION_TIMEOUT ~= K.RANKED_LAUNCHER_OUTDATED, 'kinds are distinct')

	-- late cancel: no handle left (already matched or left) -> no error, no notice, no crash
	mm.handles = {}
	shown = {}
	handlers[103]({ reason = 'verification_timeout', requeue = false })
	check(#shown == 0, 'a late timeout cancel with no ranked handle shows nothing')

	-- casual handle is never ended by a readiness cancel (it names no modId)
	local casual = { mod_id = 'MultiplayerPvP', game_mode = 'pvp_casual', fired = {}, _fire = function() error('casual fired') end }
	mm.handles = { casual }
	handlers[103]({ reason = 'verification_timeout', requeue = false })
	check(#mm.handles == 1, 'casual handle untouched')

	-- localization key exists for the body the overlay picks
	local loc = dofile('localization/en-us.lua')
	local found
	local function walk(t) for k, v in pairs(t) do if k == 'k_ranked_verification_timeout_body' then found = v elseif type(v) == 'table' then walk(v) end end end
	walk(loc)
	check(type(found) == 'string' and #found > 0, 'timeout body text is localized')
end)

T.done('queue_cancel_test')
