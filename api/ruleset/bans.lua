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
-- and any registered ban sources.
local function collect_banned_keys(ruleset, gamemode)
	local keys = {}
	local function ban(key) keys[key] = true end

	for _, category in pairs(MPAPI.BanCategory) do
		for _, v in ipairs(ruleset['banned_' .. category]) do ban(v) end
		if gamemode then
			for _, v in ipairs(gamemode['banned_' .. category] or {}) do ban(v) end
		end
	end
	for _, v in ipairs(ruleset.banned_silent) do ban(v) end

	for _, source in ipairs(MPAPI.ban_sources) do
		local result = source()
		if result then
			for k, v in pairs(result) do
				ban(type(k) == 'number' and v or k)
			end
		end
	end

	return keys
end

-- Effect: merge a source dict into a G.GAME.* dict, creating it if absent.
local function apply_to_game_table(field, source)
	if not source then return end
	G.GAME[field] = G.GAME[field] or {}
	for k, v in pairs(source) do G.GAME[field][k] = v end
end

function MPAPI.ApplyBans()
	local ruleset_key = MPAPI.get_active_ruleset()
	if not ruleset_key then return end

	local gamemode_key = MPAPI.get_active_gamemode()
	local gamemode = gamemode_key and MPAPI.GameModes[gamemode_key] or nil
	local ruleset = MPAPI.current_ruleset()

	for key in pairs(collect_banned_keys(ruleset, gamemode)) do
		G.GAME.banned_keys[key] = true
	end

	MPAPI.calculate_context({ apply_bans = true })

	apply_to_game_table('modifiers', ruleset.game_modifiers)
	apply_to_game_table('starting_params', ruleset.starting_params)
end
