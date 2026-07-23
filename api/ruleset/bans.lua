-- Applies the active ruleset's (and gamemode's) bans and game modifiers to the
-- live run. Pure collection of the key/value sets is separated from the
-- G.GAME mutation at the boundary.

-- Extension point for ban keys that don't come from a ruleset/gamemode's own
-- banned_* fields -- e.g. a compatibility shim banning content on behalf of
-- another mod. Each source is called with no arguments and may return an
-- array of keys, a set-shaped { [key] = true } table, or nil/nothing.
MPAPI.ban_sources = MPAPI.ban_sources or {}

function MPAPI.register_ban_source(fn)
	MPAPI.ban_sources[#MPAPI.ban_sources + 1] = fn
end

-- Pure: gather every banned content key from the resolved ruleset, gamemode,
-- and any registered ban sources. `keys` is the flat set every other consumer
-- (pool gating, etc.) already expects; `meta` preserves the category/loud-vs-
-- silent info that used to get discarded the instant a key landed in that flat
-- set (§9.3) -- category is one of MPAPI.BanCategory's values, 'silent', or
-- 'source'. `loud` is false only for a silent ban (§9.3: "banned but silent...
-- no player-facing notice" -- by design, not a bug); everything else, gamemode
-- bans included, is loud.
local function collect_banned_keys(ruleset, gamemode)
	local keys = {}
	local meta = {}
	local function ban(key, category, loud)
		keys[key] = true
		if not meta[key] then
			meta[key] = { category = category, loud = loud }
		end
	end

	for _, category in pairs(MPAPI.BanCategory) do
		for _, v in ipairs(ruleset['banned_' .. category]) do ban(v, category, true) end
		if gamemode then
			for _, v in ipairs(gamemode['banned_' .. category] or {}) do ban(v, category, true) end
		end
	end
	for _, v in ipairs(ruleset.banned_silent) do ban(v, 'silent', false) end
	if gamemode then
		for _, v in ipairs(gamemode.banned_silent or {}) do ban(v, 'silent', false) end
	end

	for _, source in ipairs(MPAPI.ban_sources) do
		local result = source()
		if result then
			for k, v in pairs(result) do
				ban(type(k) == 'number' and v or k, 'source', true)
			end
		end
	end

	return keys, meta
end

-- Effect: merge a source dict into a G.GAME.* dict, creating it if absent.
local function apply_to_game_table(field, source)
	if not source then return end
	G.GAME[field] = G.GAME[field] or {}
	for k, v in pairs(source) do G.GAME[field][k] = v end
end

-- Category/loud-vs-silent info for the bans applied by the most recent
-- MPAPI.ApplyBans() call -- keyed by content key, see collect_banned_keys.
-- Query via MPAPI.get_ban_info(key) rather than reading this table directly.
MPAPI._last_ban_meta = MPAPI._last_ban_meta or {}

function MPAPI.ApplyBans()
	local ruleset_key = MPAPI.get_active_ruleset()
	if not ruleset_key then return end

	local gamemode_key = MPAPI.get_active_gamemode()
	local gamemode = gamemode_key and MPAPI.GameModes[gamemode_key] or nil
	local ruleset = MPAPI.current_ruleset()

	local keys, meta = collect_banned_keys(ruleset, gamemode)
	for key in pairs(keys) do
		G.GAME.banned_keys[key] = true
	end
	MPAPI._last_ban_meta = meta

	MPAPI.calculate_context({ apply_bans = true })

	apply_to_game_table('modifiers', ruleset.game_modifiers)
	apply_to_game_table('starting_params', ruleset.starting_params)
end

-- Returns { category, loud } for a currently-banned key, or nil if it isn't
-- banned (or bans haven't been applied yet this run). `category` is one of
-- MPAPI.BanCategory's values, 'silent', or 'source'; `loud` is false only for
-- a silent ban. The natural read point for anything wanting to distinguish a
-- loud ban (fine to surface to the player) from a silent one (§9.3: no
-- player-facing notice by design) instead of re-deriving it from the flat
-- G.GAME.banned_keys set, which carries no category/loudness of its own.
function MPAPI.get_ban_info(key)
	return MPAPI._last_ban_meta[key]
end
