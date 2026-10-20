-- Group casual queue: whether a private lobby may queue as one group, and
-- the party ticket it queues with. Pure: facts in, answers out. The server
-- checks the same again (BalatroMultiplayerServer nakama/src/matchmaking/
-- group/refusal.ts); these let the UI say no before asking it.
MPAPI.matchmaking = MPAPI.matchmaking or {}
MPAPI.matchmaking.group = MPAPI.matchmaking.group or {}
local Group = MPAPI.matchmaking.group

-- refusal.ts's MIN_GROUP_SIZE / MAX_GROUP_SIZE.
Group.MIN_SIZE = 2
Group.MAX_SIZE = 8

-- Why a lobby may not queue as a group. The values are the server's refusal
-- codes (refusal.ts GroupRefusalCode), so one localization key per code
-- (k_group_refused_<code>) covers a refusal from either side.
-- MODE_TOO_SMALL is client-side only: the mode can't seat the group and at
-- least one other player (or, for Teams, a whole other team).
Group.Refusal = {
	DISABLED = 'disabled',
	NOT_IN_LOBBY = 'not_in_lobby',
	NOT_HOST = 'not_host',
	NOT_PRIVATE = 'not_private',
	RANKED = 'ranked',
	IN_GAME = 'in_game',
	ALREADY_QUEUED = 'already_queued',
	TOO_FEW = 'too_few',
	TOO_MANY = 'too_many',
	MEMBER_AWAY = 'member_away',
	MEMBER_REFUSED = 'member_refused',
	MEMBER_QUEUED = 'member_queued',
	BAD_REQUEST = 'bad_request',
	PARTY_IN_USE = 'party_in_use',
	PARTY_MISMATCH = 'party_mismatch',
	NOT_BOUND = 'not_bound',
	NOT_FORMING = 'not_forming',
	GROUP_AWAY = 'group_away',
	NOT_LEADER = 'not_leader',
	NOT_MEMBER = 'not_member',
	TICKET_MISMATCH = 'ticket_mismatch',
	BAD_COUNTS = 'bad_counts',
	MODE_TOO_SMALL = 'mode_too_small',
}

-- The phases of a group queue (the server's GroupPhase, plus 'idle' which
-- only op 112 carries: the queue ended).
Group.Phase = { FORMING = 'forming', QUEUED = 'queued', AWAY = 'away', IDLE = 'idle' }

local function refusal(code, user_id)
	return { code = code, user_id = user_id }
end

-- Whether a mode can seat a group of `size`: one stranger at least, or for
-- Teams a whole other team of them. mode = { max_players, teams }. Pure.
function Group.mode_fits(mode, size)
	local max = mode and mode.max_players or 0
	if mode and mode.teams then
		return max >= 2 * size
	end
	return max >= size + 1
end

-- The first reason the lobby described by `facts` may not queue as a group
-- for `mode`, or nil. facts = { in_lobby, is_host, is_private, ranked,
-- in_game, queueing, member_ids = {..}, away_ids = {..} }; mode as
-- mode_fits (nil skips that check). Checked in the server's order
-- (refusal.ts homeRefusal). Pure.
function Group.eligibility(facts, mode)
	local R = Group.Refusal
	if not facts or not facts.in_lobby then
		return refusal(R.NOT_IN_LOBBY)
	end
	if not facts.is_host then
		return refusal(R.NOT_HOST)
	end
	if not facts.is_private then
		return refusal(R.NOT_PRIVATE)
	end
	if facts.ranked then
		return refusal(R.RANKED)
	end
	if facts.in_game then
		return refusal(R.IN_GAME)
	end
	if facts.queueing then
		return refusal(R.ALREADY_QUEUED)
	end
	local size = #(facts.member_ids or {})
	if size < Group.MIN_SIZE then
		return refusal(R.TOO_FEW)
	end
	if size > Group.MAX_SIZE then
		return refusal(R.TOO_MANY)
	end
	local away = (facts.away_ids or {})[1]
	if away then
		return refusal(R.MEMBER_AWAY, away)
	end
	if mode and not Group.mode_fits(mode, size) then
		return refusal(R.MODE_TOO_SMALL)
	end
	return nil
end

-- `modes` (a list of { key, max_players, teams, ... }) each with its
-- refusal (nil = may queue). Pure.
function Group.rank_modes(facts, modes)
	local out = {}
	for _, mode in ipairs(modes or {}) do
		out[#out + 1] = { mode = mode, refusal = Group.eligibility(facts, mode) }
	end
	return out
end

-- The party ticket for a group of `size` queueing `opts` (MPAPI.matchmaking.
-- queue's opts, plus opts.teams). Counts as refusal.ts countRefusal wants:
-- at least one stranger (min > size); Teams in steps of two with a whole
-- other team (min >= 2 * size, even). nil, refusal when the mode's
-- max_players can't fit that. Pure.
function Group.party_ticket(opts, size, teams)
	local base = MPAPI.matchmaking._nakama_ticket(opts, false)
	local min = math.max(base.min_count, size + 1)
	local max = base.max_count
	local count_multiple = nil
	if teams then
		min = math.max(min, 2 * size)
		if min % 2 == 1 then
			min = min + 1
		end
		if max % 2 == 1 then
			max = max - 1
		end
		count_multiple = 2
	end
	if max < min then
		return nil, refusal(Group.Refusal.MODE_TOO_SMALL)
	end
	local numbers = { groupSize = size }
	if teams then
		numbers.teams = 1
	end
	return {
		min_count = min,
		max_count = max,
		count_multiple = count_multiple,
		query = base.query,
		strings = base.strings,
		numbers = numbers,
	}
end

-- The facts Group.eligibility reads, gathered from a lobby object (nil =
-- not in a lobby). Reads only.
function Group.facts_from_lobby(lobby)
	if not lobby or lobby._destroyed then
		return { in_lobby = false }
	end
	local member_ids, away_ids = {}, {}
	for _, p in ipairs(lobby:get_players()) do
		member_ids[#member_ids + 1] = p.id
		if p.is_away then
			away_ids[#away_ids + 1] = p.id
		end
	end
	table.sort(member_ids)
	table.sort(away_ids)
	return {
		in_lobby = true,
		is_host = lobby.is_host and true or false,
		is_private = (lobby.type or 'private') == 'private' and not lobby._local_mode,
		ranked = lobby.type == 'ranked',
		in_game = lobby:is_game_started(),
		queueing = lobby.group_queue ~= nil,
		member_ids = member_ids,
		away_ids = away_ids,
	}
end

-- The player-facing text for a refusal: k_group_refused_<code>, else the
-- server's own message, else the code.
function Group.refusal_text(r)
	if type(r) ~= 'table' then
		return tostring(r)
	end
	local key = 'k_group_refused_' .. tostring(r.code)
	local text = G and G.localization and G.localization.misc and G.localization.misc.dictionary
		and G.localization.misc.dictionary[key]
	if text then
		if r.detail and r.detail ~= '' then
			return text .. ' ' .. r.detail
		end
		return text
	end
	return r.message or tostring(r.code)
end
