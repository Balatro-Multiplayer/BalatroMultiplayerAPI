-- §22.2/§22.3: merges every player's own carbon log (as returned by
-- MPAPI.replay.get, api/replay/api.lua) into a single timestamp-ordered
-- timeline, tagged with which player performed each action.
--
-- Each player's carbon log is a separately gzip+base64'd JSON array of
-- [t, opcode, args] tuples (see BalatroMultiplayerPvP/lib/replay_log.lua's
-- RLOG.record/canonical_hash_input for the exact wire shape this mirrors) --
-- one blob per player, never pre-merged across players server-side. `t` is
-- elapsed-ms since THAT player's own manifest (recorded independently on
-- each client at match start), so streams are aligned on each one's own t=0
-- rather than assuming zero cross-client clock skew.
MPAPI.playback = MPAPI.playback or {}

-- logs: the `logs` array from MPAPI.replay.get's callback data (one entry per
-- player: {playerId, compressedEvents, carbonHash, eventCount, status, flagReason}).
-- Returns an array of {t, player_id, opcode, args}, sorted by t ascending.
function MPAPI.playback.build_timeline(logs)
	local timeline = {}

	for _, log in ipairs(logs or {}) do
		local raw, decompress_err = MPAPI.decompress_str(log.compressedEvents)
		if not raw then
			MPAPI.sendWarnMessage(
				'MPAPI.playback.build_timeline: failed to decompress player '
					.. tostring(log.playerId) .. ': ' .. tostring(decompress_err)
			)
		else
			local ok, events = pcall(MPAPI.json_decode, raw)
			if not ok or type(events) ~= 'table' then
				MPAPI.sendWarnMessage(
					'MPAPI.playback.build_timeline: failed to decode player ' .. tostring(log.playerId) .. ' events'
				)
			else
				for _, ev in ipairs(events) do
					-- [t, opcode, args] positional tuple (see encode_event_tuple in
					-- replay_log.lua) -- not an {t=,opcode=,args=} object.
					if ev[1] ~= nil then
						timeline[#timeline + 1] = {
							t = ev[1],
							player_id = log.playerId,
							opcode = ev[2],
							args = ev[3],
						}
					end
				end
			end
		end
	end

	table.sort(timeline, function(a, b)
		return a.t < b.t
	end)

	return timeline
end
