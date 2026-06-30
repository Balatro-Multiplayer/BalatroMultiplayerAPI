MPAPI.matchmaking = MPAPI.matchmaking or {}

-- Shared matchmaking state and the helpers that operate on it. Kept in one place
-- so the handle, dispatch and public-API files reach it through MPAPI._internal.mm
-- rather than capturing file-local upvalues (which cannot cross files). Defensive
-- init keeps the four matchmaking files independent of load order.
MPAPI._internal.mm = MPAPI._internal.mm or {}
local mm = MPAPI._internal.mm

mm.handles = mm.handles or {} -- active queue handles
if mm.subscribed == nil then
	mm.subscribed = false -- whether we are subscribed to our matchmaking topic
end

-- Pure: the per-player matchmaking topic.
function mm.topic(player_id)
	return 'player/' .. player_id .. '/matchmaking'
end

function mm.find_handle_by_mode(mod_id, game_mode)
	for _, h in ipairs(mm.handles) do
		if h.mod_id == mod_id and h.game_mode == game_mode then
			return h
		end
	end
	return nil
end

function mm.find_handle_by_match_id(match_id)
	for _, h in ipairs(mm.handles) do
		if h.match_id == match_id then
			return h
		end
	end
	return nil
end

function mm.ensure_subscribed()
	if mm.subscribed then
		return
	end
	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()
	if not conn or not mqtt then
		return
	end

	local topic = mm.topic(conn.player_id)
	MPAPI.sendDebugMessage('[mmdbg] ensure_subscribed: subscribing to ' .. tostring(topic) .. ' (player_id=' .. tostring(conn.player_id) .. ')')

	-- The mqtt client invokes handlers as (topic, payload); the payload is the
	-- second argument. (Taking only the first dropped every matchmaking message --
	-- e.g. match_found -- because the topic string is not valid JSON.)
	mqtt:subscribe(topic, 1, function(_topic, payload_str)
		MPAPI.sendDebugMessage('[mmdbg] matchmaking MQTT message on ' .. tostring(_topic) .. ' raw=' .. tostring(payload_str))
		local ok, msg = pcall(MPAPI.json_decode, payload_str)
		if not ok or not msg then
			MPAPI.sendDebugMessage('[mmdbg] matchmaking message decode FAILED ok=' .. tostring(ok))
			return
		end
		mm.dispatch(msg)
	end)

	mm.subscribed = true
end

function mm.unsubscribe_if_empty()
	if #mm.handles > 0 then
		return
	end
	if not mm.subscribed then
		return
	end

	local conn = MPAPI.get_connection()
	local mqtt = MPAPI.get_mqtt()
	if not conn or not mqtt then
		mm.subscribed = false
		return
	end

	mqtt:unsubscribe(mm.topic(conn.player_id))
	mm.subscribed = false
end

function mm.remove_handle(handle)
	for i, h in ipairs(mm.handles) do
		if h == handle then
			table.remove(mm.handles, i)
			break
		end
	end
	mm.unsubscribe_if_empty()
end
