-- Applies the active ruleset's (and gamemode's) bans and game modifiers to the
-- live run. Pure collection of the key/value sets is separated from the
-- G.GAME mutation at the boundary.

-- Pure: gather every banned content key from the resolved ruleset and gamemode.
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

	MPAPI.RunLayerHooks('on_apply_bans')

	apply_to_game_table('modifiers', ruleset.game_modifiers)
	apply_to_game_table('starting_params', ruleset.starting_params)
end
