-- The Party lobby: a private lobby with no game of its own. The host queues
-- its players together for a casual mode (the group queue, queue.lua) and
-- they come back to it after the game (home.lua). The host's metadata says it
-- is one (kind = party), so a joiner and a player back from the game see it
-- too. Each mod draws its own lobby view and casual mode picker.
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI.matchmaking.group = MPAPI.matchmaking.group or {}
local Group = MPAPI.matchmaking.group

MPAPI.Party = {
	-- The lobby metadata kind of a Party lobby.
	KIND = 'party',
	-- The lobby this client just created as a Party lobby, before the host's
	-- metadata write comes back from the server.
	created = nil,
}
local Party = MPAPI.Party

function Party.is_party_lobby(lobby)
	return lobby == Party.created or lobby:get_metadata().kind == Party.KIND
end

-- Whether this client knows what kind of lobby it is in. The host always does; a
-- joiner learns it from the host's metadata, which lands just after the join.
function Party.kind_known(lobby)
	return lobby.is_host or lobby:get_metadata().kind ~= nil
end

-- Whether the host may open Find Game: two players or more (no more than a
-- group may be), every player except the host ready, and no queue running.
-- facts = { is_host, queueing, self_id, player_ids = {..}, ready = { [id] = true } }. Pure.
function Party.find_game_enabled(facts)
	if not facts.is_host or facts.queueing then
		return false
	end
	local ids = facts.player_ids
	if #ids < Group.MIN_SIZE or #ids > Group.MAX_SIZE then
		return false
	end
	for _, id in ipairs(ids) do
		if id ~= facts.self_id and not facts.ready[id] then
			return false
		end
	end
	return true
end

-- The facts find_game_enabled reads, from the lobby and the mod's ready tally.
function Party.find_game_facts(lobby, ready_tracker)
	if not lobby then
		return { is_host = false, ready = {} }
	end
	local ids, ready = {}, {}
	for _, p in ipairs(lobby:get_players()) do
		ids[#ids + 1] = p.id
		ready[p.id] = ready_tracker:is_ready(p.id) and true or false
	end
	return {
		is_host = lobby.is_host and true or false,
		queueing = lobby.group_queue ~= nil,
		self_id = lobby.player_id,
		player_ids = ids,
		ready = ready,
	}
end

-- Create a Party lobby for mod_id. setup(lobby) wires the mod's lobby events
-- before the lobby connects. Returns the lobby, or nil.
function Party.create(mod_id, setup)
	if MPAPI.matchmaking.guard_queued(function()
		return Party.create(mod_id, setup)
	end) then
		return nil
	end
	local lobby = MPAPI.create_lobby(mod_id, { max_players = Group.MAX_SIZE })
	if not lobby then
		MPAPI.sendWarnMessage('Party.create: failed to create lobby')
		return nil
	end
	Party.created = lobby
	setup(lobby)
	lobby:on(MPAPI.LobbyEvent.CONNECTED, function()
		if lobby.is_host then
			lobby:set_metadata({ kind = Party.KIND })
		end
		if love and love.system and love.system.setClipboardText then
			pcall(love.system.setClipboardText, lobby.code)
		end
		MPAPI.refresh_current_view()
	end)
	return lobby
end
