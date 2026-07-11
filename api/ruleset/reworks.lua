-- Center stat/behavior reworks: registration, baking vanilla + reworked variants
-- onto each center at SMODS injection time, and applying the active rework chain
-- onto the live centers (effects against G.* / SMODS pools).

-- Sentinel layer name for the unmodified vanilla variant of a center.
local VANILLA = 'vanilla'
-- Marker stored in place of a missing property so it round-trips back to nil.
local ABSENT = 'NULL'

local LOADED_REWORKS = {}

-- Register a center stat/behavior patch for specific layer(s). Multiple calls for
-- the same key accumulate, each targeting its own layer slot.
---@param key string  e.g. "j_glass"
---@param opts table  { layers, loc_key?, silent?, center_table?, ...center properties }
function MPAPI.ReworkCenter(key, opts)
	LOADED_REWORKS[key] = LOADED_REWORKS[key] or {}
	table.insert(LOADED_REWORKS[key], opts or {})
end

local function resolve_center_table(opts)
	return (type(opts.center_table) == 'table' and opts.center_table)
		or G[opts.center_table]
		or G.P_CENTERS
end

local function wrap_loc_vars_with_key(opts, loc_key)
	local user_loc_vars = opts.loc_vars or function() return {} end
	opts.loc_vars = function(self, info_queue, card)
		local result = user_loc_vars(self, info_queue, card)
		result.key = loc_key
		return result
	end
end

local function bake_variant(center, opts, layer, reserved, needs_generate_ui, silent)
	local prefix = 'mp_' .. layer .. '_'
	for k, v in pairs(opts) do
		if not reserved[k] then
			center[prefix .. k] = v
			if not center['mp_vanilla_' .. k] then
				center['mp_vanilla_' .. k] = center[k] or ABSENT
			end
		end
	end
	if needs_generate_ui then
		center[prefix .. 'generate_ui'] = SMODS.Center.generate_ui
		if not center.mp_vanilla_generate_ui then
			center.mp_vanilla_generate_ui = center.generate_ui or ABSENT
		end
	end
	center.mp_reworks = center.mp_reworks or {}
	center.mp_reworks[layer] = true
	center.mp_reworks[VANILLA] = true
	center.mp_silent = center.mp_silent or {}
	center.mp_silent[layer] = silent
end

local function bake_rework(key, opts)
	local center = resolve_center_table(opts)[key]
	if not center then
		MPAPI.sendWarnMessage('[ruleset] ReworkCenter: unknown center key: ' .. tostring(key))
		return
	end

	local reserved = { layers = true, loc_key = true, silent = true, center_table = true }
	local layers = opts.layers
	if type(layers) == 'string' then layers = { layers } end

	if opts.loc_key then wrap_loc_vars_with_key(opts, opts.loc_key) end

	local needs_generate_ui = opts.loc_vars
		and not opts.generate_ui
		and not (center.generate_ui and type(center.generate_ui) == 'function')

	if center.config then
		opts.config = opts.config or copy_table(center.config)
		opts.config.mp_balanced = true
	end

	for _, layer in ipairs(layers) do
		bake_variant(center, opts, layer, reserved, needs_generate_ui, opts.silent)
	end
end

local _inject_ref = SMODS.injectItems
function SMODS.injectItems()
	local ret = _inject_ref()
	for key, opts_list in pairs(LOADED_REWORKS) do
		for _, opts in ipairs(opts_list) do
			bake_rework(key, opts)
		end
	end
	return ret
end

-- Copy a single baked variant's properties back onto the live center, restoring
-- the rarity pool when the rarity property changes.
local function apply_variant(center, prefix)
	for k in pairs(center) do
		if string.sub(k, 1, #prefix) == prefix then
			local orig = string.sub(k, #prefix + 1)
			if orig == 'rarity' then
				SMODS.remove_pool(G.P_JOKER_RARITY_POOLS[center[orig]], center.key)
				table.insert(G.P_JOKER_RARITY_POOLS[center[k]], center)
				table.sort(G.P_JOKER_RARITY_POOLS[center[k]], function(a, b) return a.order < b.order end)
			end
			center[orig] = (center[k] == ABSENT) and nil or center[k]
		end
	end
end

local function apply_chain_to_center(center, resolution)
	apply_variant(center, 'mp_vanilla_')
	for _, layer in ipairs(resolution) do apply_variant(center, 'mp_' .. layer .. '_') end
end

-- Apply the rework chain for the given ruleset key (VANILLA to reset). Resolves
-- via active_layer_chain: vanilla pass first, then layers in order. Optionally
-- restrict to a single center key.
function MPAPI.LoadReworks(ruleset_key, key)
	ruleset_key = ruleset_key or VANILLA
	local resolution = MPAPI.active_layer_chain(ruleset_key)
	local tables = { G.P_CENTERS, G.P_TAGS, G.P_SEALS, SMODS.PokerHands, G.P_STAKES, G.P_BLINDS }

	if key then
		for _, tbl in ipairs(tables) do
			if tbl[key] then
				apply_chain_to_center(tbl[key], resolution)
				break
			end
		end
		return
	end

	for _, tbl in ipairs(tables) do
		for k, v in pairs(tbl) do
			if v.mp_reworks then
				if v.mp_reworks[VANILLA] then apply_variant(v, 'mp_vanilla_') end
				for _, layer in ipairs(resolution) do
					if v.mp_reworks[layer] then apply_variant(v, 'mp_' .. layer .. '_') end
				end
			end
		end
	end
end

local _start_run_ref = Game.start_run
function Game:start_run(args)
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	local ruleset_key = lobby and lobby:get_metadata().ruleset or nil
	-- Only drive the API's rework engine when the active ruleset is one the API
	-- actually owns (an MPAPI.Ruleset), or when there is no ruleset at all (vanilla
	-- reset for base-game / non-lobby play). Consumer mods that keep their own
	-- rework system (e.g. MultiplayerPvP, whose centers are baked into the SAME
	-- mp_reworks/mp_vanilla_* namespace) select non-API ruleset keys; running
	-- LoadReworks for those would reset their reworked centers back to vanilla and
	-- clobber their content. In that case we leave the centers alone and let the
	-- consumer mod's own LoadReworks own them.
	if ruleset_key == nil or (MPAPI.Rulesets and MPAPI.Rulesets[ruleset_key]) then
		MPAPI.LoadReworks(ruleset_key)
	end
	return _start_run_ref(self, args)
end
