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

-- Whether a member's standing going from `before` to `after` can change
-- member_standing_refusal's answer: only none refuses. Pure.
function Group.changes_refusal(before, after)
	return (before == MPAPI.Standing.NONE) ~= (after == MPAPI.Standing.NONE)
end

-- The member whose standing (domain/standing.lua) refuses the group, as a
-- MEMBER_REFUSED refusal { code, user_id, name, reason, mods }, or nil. A
-- group is casual only, so a member counts as refused when the lobby says
-- their standing is none, or, for this client itself, when its own standing
-- refuses casual. reason (an MPAPI.QueueRefusalCode) and mods come from this
-- client's own standing for itself, else from what the server last said
-- about that member (facts.known_refusals), else stay unknown. Members are
-- checked in member_ids order. Pure.
function Group.member_standing_refusal(facts)
	for _, id in ipairs(facts.member_ids or {}) do
		local own = id == facts.own_id and facts.own_refusal or nil
		if own or (facts.standings or {})[id] == MPAPI.Standing.NONE then
			local known = own or (facts.known_refusals or {})[id] or {}
			return {
				code = Group.Refusal.MEMBER_REFUSED,
				user_id = id,
				name = (facts.names or {})[id],
				reason = known.code,
				mods = known.mods or {},
			}
		end
	end
	return nil
end

-- The first reason the lobby described by `facts` may not queue as a group
-- for `mode`, or nil. facts = { in_lobby, is_host, is_private, ranked,
-- in_game, queueing, member_ids = {..}, away_ids = {..}, and for
-- member_standing_refusal: standings, names, own_id, own_refusal,
-- known_refusals }; mode as mode_fits (nil skips that check). Checked in the
-- server's order (refusal.ts homeRefusal, then memberRefusal). Pure.
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
	local refused = Group.member_standing_refusal(facts)
	if refused then
		return refused
	end
	if mode and not Group.mode_fits(mode, size) then
		return refusal(R.MODE_TOO_SMALL)
	end
	return nil
end

-- facts with every member's standing left out, for the checks that don't
-- depend on it (which modes fit, whether to ask the server at all). Pure.
function Group.without_standings(facts)
	local copy = {}
	for k, v in pairs(facts or {}) do
		copy[k] = v
	end
	copy.standings = {}
	copy.own_refusal = nil
	return copy
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
	local member_ids, away_ids, standings, names = {}, {}, {}, {}
	for _, p in ipairs(lobby:get_players()) do
		member_ids[#member_ids + 1] = p.id
		if p.is_away then
			away_ids[#away_ids + 1] = p.id
		end
		standings[p.id] = p.standing
		names[p.id] = p.displayName
	end
	table.sort(member_ids)
	table.sort(away_ids)
	local own_refusal = MPAPI.standing.queue_refusal(MPAPI.account_standing(), MPAPI.QueueKind.CASUAL, MPAPI.is_launcher_verified())
	return {
		standings = standings,
		names = names,
		own_id = lobby.player_id,
		own_refusal = own_refusal,
		known_refusals = Group.known_refusals_for(lobby.code),
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

-- What the server last said about members refused for their standing, per
-- home lobby code: { [code] = { [user_id] = { code, mods } } }. The lobby
-- snapshot only says a member's standing is none; the server's refusal (a
-- refused open, or op 112 ending the queue) also says why.
Group._known_refusals = Group._known_refusals or {}

function Group.known_refusals_for(home_code)
	return Group._known_refusals[home_code or ''] or {}
end

-- A server refusal ({ userId, reason, mods }, as group_queue_open and op 112
-- carry it) kept for that home lobby.
function Group.remember_refusal(home_code, refused)
	if type(refused) ~= 'table' or not refused.userId or not refused.reason then
		return
	end
	local key = home_code or ''
	Group._known_refusals[key] = Group._known_refusals[key] or {}
	local mods = {}
	for _, m in ipairs(type(refused.mods) == 'table' and refused.mods or {}) do
		mods[#mods + 1] = tostring(m)
	end
	Group._known_refusals[key][refused.userId] = { code = refused.reason, mods = mods }
end

-- A server MEMBER_REFUSED ({ code, userId, reason, mods, detail, message })
-- in the shape member_standing_refusal returns, named from `names`
-- ({ [user_id] = displayName }). Pure.
function Group.member_refusal_from_server(refused, names)
	local mods = {}
	for _, m in ipairs(type(refused.mods) == 'table' and refused.mods or {}) do
		mods[#mods + 1] = tostring(m)
	end
	return {
		code = Group.Refusal.MEMBER_REFUSED,
		user_id = refused.userId,
		name = (names or {})[refused.userId],
		reason = refused.reason,
		mods = mods,
		detail = refused.detail,
		message = refused.message,
	}
end

-- "Player001 has mods that aren't allowed: ClaudeControl" for a member
-- refused for their standing, by its reason (k_group_member_<reason>).
function Group.member_refusal_text(r)
	local name = r.name or r.user_id or r.userId or '?'
	local text = localize('k_group_member_' .. tostring(r.reason))
	if text == 'ERROR' then
		text = localize('k_group_member_unknown')
	end
	text = text:gsub('#1#', name)
	if r.mods and #r.mods > 0 then
		text = text .. ' ' .. MPAPI.standing.format_mods(MPAPI.standing.mod_names(r.mods))
	end
	return text
end

-- The player-facing text for a refusal: k_group_refused_<code>, else the
-- server's own message, else the code. A member refused for their standing
-- is named, with the mods when known.
function Group.refusal_text(r)
	if type(r) ~= 'table' then
		return tostring(r)
	end
	if r.code == Group.Refusal.MEMBER_REFUSED and (r.name or r.reason) then
		return Group.member_refusal_text(r)
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
