-- How an avatar's unlock goal reads and how far along it is. Pure: a goal is
-- the server's { kind, key, threshold, progress } (BalatroMultiplayerServer
-- nakama/src/achievements/rpc.ts, avatar_catalog), and the wording mirrors the
-- website's (apps/web/src/app/(home)/profile/avatar-goals.ts).
MPAPI.avatars = MPAPI.avatars or {}
local Goals = {}

Goals.Kind = {
	COUNTER = 'counter',
	DECK_GAMES = 'deckGames',
	ALL_OF = 'allOf',
	MILESTONE = 'milestone',
	ALL_UNLOCKABLE = 'allUnlockable',
	PRIVILEGE = 'privilege',
	RESERVED = 'reserved',
}

-- An avatar's group on the Achievements tab: its goal's kind, or DEFAULT for
-- the avatars everyone has (goal null).
Goals.Group = {
	DEFAULT = 'default',
	COUNTER = Goals.Kind.COUNTER,
	DECK_GAMES = Goals.Kind.DECK_GAMES,
	ALL_OF = Goals.Kind.ALL_OF,
	MILESTONE = Goals.Kind.MILESTONE,
	ALL_UNLOCKABLE = Goals.Kind.ALL_UNLOCKABLE,
	PRIVILEGE = Goals.Kind.PRIVILEGE,
	RESERVED = Goals.Kind.RESERVED,
	-- A kind this client doesn't know yet (a newer server).
	OTHER = 'other',
}

Goals.GROUP_ORDER = {
	Goals.Group.DEFAULT,
	Goals.Group.COUNTER,
	Goals.Group.DECK_GAMES,
	Goals.Group.ALL_OF,
	Goals.Group.MILESTONE,
	Goals.Group.ALL_UNLOCKABLE,
	Goals.Group.PRIVILEGE,
	Goals.Group.RESERVED,
	Goals.Group.OTHER,
}

local KNOWN_KIND = {}
for _, kind in pairs(Goals.Kind) do
	KNOWN_KIND[kind] = true
end

-- Kinds whose count says nothing: held or not, there are no steps to show.
local COUNTLESS_KIND = {
	[Goals.Kind.PRIVILEGE] = true,
	[Goals.Kind.RESERVED] = true,
}

local function dictionary()
	return (G.localization and G.localization.misc and G.localization.misc.dictionary) or {}
end

local function format_count(n)
	if n == math.floor(n) then
		return string.format('%d', n)
	end
	return tostring(n)
end

-- The dictionary text for `key` with #1#, #2#, ... replaced by `vars`; nil
-- when the key is missing. Shared by the avatar UIs for their own strings.
local function dictionary_text(key, vars)
	local text = dictionary()[key]
	if type(text) ~= 'string' then
		return nil
	end
	return (text:gsub('#(%d+)#', function(i)
		local v = vars and vars[tonumber(i)]
		return v ~= nil and tostring(v) or ''
	end))
end

function Goals.threshold(goal)
	return math.max(1, tonumber(goal and goal.threshold) or 1)
end

-- Progress clamped to [0, threshold]: the server doesn't cap it.
function Goals.progress(goal)
	local progress = tonumber(goal and goal.progress) or 0
	return math.max(0, math.min(progress, Goals.threshold(goal)))
end

-- 0..1, for a progress bar.
function Goals.fraction(goal)
	return Goals.progress(goal) / Goals.threshold(goal)
end

-- Worth showing as "progress / threshold": goals with more than one step.
function Goals.has_shown_progress(goal)
	return goal ~= nil and Goals.threshold(goal) > 1 and not COUNTLESS_KIND[goal.kind]
end

-- "3 / 10", or nil when the goal has no steps to show.
function Goals.progress_text(goal)
	if not Goals.has_shown_progress(goal) then
		return nil
	end
	return format_count(Goals.progress(goal)) .. ' / ' .. format_count(Goals.threshold(goal))
end

function Goals.group_of(entry)
	local goal = entry and entry.goal
	if goal == nil then
		return Goals.Group.DEFAULT
	end
	return KNOWN_KIND[goal.kind] and goal.kind or Goals.Group.OTHER
end

-- Display name of a vanilla deck key ("b_blue" -> "Blue Deck").
local function deck_name(deck_key)
	local ok, name = pcall(localize, { type = 'name_text', set = 'Back', key = deck_key })
	if ok and type(name) == 'string' and name ~= '' and name ~= 'ERROR' then
		return name
	end
	local bare = tostring(deck_key):gsub('^b_', '')
	return bare:sub(1, 1):upper() .. bare:sub(2) .. ' Deck'
end

-- The dictionary key for a goal: k_avatar_goal_<kind>_<key>, with a _one
-- variant for a threshold of 1 ("Win a game" vs "Win #1# games").
local function goal_key(goal)
	if goal.kind == Goals.Kind.DECK_GAMES then
		return 'k_avatar_goal_deckGames'
	end
	if goal.kind == Goals.Kind.ALL_UNLOCKABLE or COUNTLESS_KIND[goal.kind] then
		return 'k_avatar_goal_' .. goal.kind
	end
	return 'k_avatar_goal_' .. goal.kind .. '_' .. tostring(goal.key)
end

-- How the goal reads ("Win 10 games"). A goal this client has no wording for
-- reads as the generic "Keep playing to unlock".
function Goals.text(goal)
	if goal == nil then
		return dictionary_text('k_avatar_goal_default') or ''
	end
	local threshold = Goals.threshold(goal)
	local key = goal_key(goal)
	local vars = { format_count(threshold) }
	if goal.kind == Goals.Kind.DECK_GAMES then
		vars[2] = deck_name(goal.key)
	end
	local text = (threshold == 1 and dictionary_text(key .. '_one', vars)) or dictionary_text(key, vars)
	return text or dictionary_text('k_avatar_goal_unknown') or tostring(goal.key)
end

function Goals.group_label(group)
	return dictionary_text('k_avatar_group_' .. group) or group
end

Goals.localized = dictionary_text

MPAPI.avatars.goals = Goals
