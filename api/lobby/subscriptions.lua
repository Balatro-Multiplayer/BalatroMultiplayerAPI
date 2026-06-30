-- Wires a networked lobby's MQTT topics to the inbound handlers. The only place
-- lobby subscriptions are created.
MPAPI._internal.lobby = MPAPI._internal.lobby or {}
local L = MPAPI._internal.lobby

L.subscribe_all = function(lobby)
	if not lobby._mqtt or not lobby.code then
		return
	end

	local events_topic = lobby._mqtt:lobby_topic(lobby.code, 'events')
	lobby._mqtt:subscribe(events_topic, 1, function(topic, payload)
		L.handle_event(lobby, payload)
	end)

	local metadata_topic = lobby._mqtt:lobby_topic(lobby.code, 'metadata')
	lobby._mqtt:subscribe(metadata_topic, 1, function(topic, payload)
		L.handle_metadata(lobby, payload)
	end)

	local state_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/' .. lobby.player_id .. '/state')
	lobby._mqtt:subscribe(state_topic, 1, function(topic, payload)
		L.handle_own_state(lobby, payload)
	end)

	local info_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/+/info')
	lobby._mqtt:subscribe(info_topic, 1, function(topic, payload)
		L.handle_player_info(lobby, topic, payload)
	end)

	local actions_topic = lobby._mqtt:lobby_topic(lobby.code, 'players/+/actions')
	lobby._mqtt:subscribe(actions_topic, 1, function(topic, payload)
		MPAPI._internal.handle_action(lobby, topic, payload)
	end)

	MPAPI.chat.init(lobby)
end
