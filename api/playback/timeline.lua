-- §22.2/§22.3: merges every player's own carbon log (as returned by
-- MPAPI.replay.get, api/replay/api.lua) into a single timestamp-ordered
-- timeline, tagged with which player performed each action.
--
-- Each player's carbon log is a separately gzip+base64'd JSON array of
-- [t, opcode, args] tuples (see api/replay/recorder.lua's
-- RLOG.record/canonical_hash_input for the exact wire shape this mirrors) --
-- one blob per player, never pre-merged across players server-side. `t` is
-- elapsed-ms since THAT player's own manifest (recorded independently on
-- each client at match start), so streams are aligned on each one's own t=0
-- rather than assuming zero cross-client clock skew.
MPAPI.playback = MPAPI.playback or {}

local function add_events(timeline, player_id, events)
	for _, ev in ipairs(events) do
		-- [t, opcode, args] positional tuple (see encode_event_tuple in
		-- recorder.lua) -- not an {t=,opcode=,args=} object.
		if ev[1] ~= nil then
			timeline[#timeline + 1] = {
				t = ev[1],
				player_id = player_id,
				opcode = ev[2],
				args = ev[3],
			}
		end
	end
end

-- An API-stored log: gzip+base64'd JSON.
local function add_compressed_log(timeline, log)
	local raw, decompress_err = MPAPI.decompress_str(log.compressedEvents)
	if not raw then
		MPAPI.sendWarnMessage(
			'MPAPI.playback.build_timeline: failed to decompress player '
				.. tostring(log.playerId) .. ': ' .. tostring(decompress_err)
		)
		return
	end
	local ok, events = pcall(MPAPI.json_decode, raw)
	if not ok or type(events) ~= 'table' then
		MPAPI.sendWarnMessage(
			'MPAPI.playback.build_timeline: failed to decode player ' .. tostring(log.playerId) .. ' events'
		)
		return
	end
	add_events(timeline, log.playerId, events)
end

-- logs: the `logs` array from MPAPI.replay.get's callback data (one entry per
-- player: {playerId, compressedEvents, carbonHash, eventCount, status, flagReason}).
-- A Nakama-stored run's logs come already decoded, as `events`.
-- Returns an array of {t, player_id, opcode, args}, sorted by t ascending.
function MPAPI.playback.build_timeline(logs)
	local timeline = {}

	for _, log in ipairs(logs or {}) do
		if type(log.events) == 'table' then
			add_events(timeline, log.playerId, log.events)
		else
			add_compressed_log(timeline, log)
		end
	end

	table.sort(timeline, function(a, b)
		return a.t < b.t
	end)

	return timeline
end
