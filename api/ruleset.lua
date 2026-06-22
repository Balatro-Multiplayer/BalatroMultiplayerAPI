-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the ruleset system this is based on.

G.P_CENTER_POOLS.Ruleset = {}
MPAPI.Rulesets = {}

-----------------------------
-- Ruleset constructor
-----------------------------

local RulesetMeta = {}
RulesetMeta.__index = RulesetMeta

function RulesetMeta:inject()
	MPAPI.Rulesets[self.key] = self
	if not G.P_CENTER_POOLS.Ruleset then G.P_CENTER_POOLS.Ruleset = {} end
	table.insert(G.P_CENTER_POOLS.Ruleset, self)
end

function MPAPI.Ruleset(init)
	assert(type(init) == 'table' and init.key, 'MPAPI.Ruleset: key is required')
	init = MPAPI.resolve_layers(init)

	-- Populate reverse indices for reworked entries defined directly on the ruleset
	-- (entries pulled in from layers are already indexed when MPAPI.Layer() was called).
	local function index_list(list, index_table, name)
		if not list then return end
		for _, key in ipairs(list) do
			index_table[key] = index_table[key] or {}
			table.insert(index_table[key], name)
		end
	end
	index_list(init.reworked_jokers,      MPAPI._JOKER_LAYERS,      init.key)
	index_list(init.reworked_consumables, MPAPI._CONSUMABLE_LAYERS, init.key)
	index_list(init.reworked_tags,        MPAPI._TAG_LAYERS,        init.key)

	return setmetatable(init, RulesetMeta)
end

-----------------------------
-- Active ruleset / gamemode
-----------------------------

-- Returns the full ruleset key from the current lobby's metadata, or nil.
function MPAPI.get_active_ruleset()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if lobby then return lobby:get_metadata().ruleset end
	return nil
end

-- Returns the full gamemode key from the current lobby's metadata, or nil.
function MPAPI.get_active_gamemode()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if lobby then return lobby:get_metadata().gamemode end
	return nil
end

function MPAPI.is_ruleset_active(ruleset_key)
	return MPAPI.get_active_ruleset() == ruleset_key
end

-----------------------------
-- current_ruleset() resolver
-----------------------------

local _array_field_set = {}
for _, f in ipairs(MPAPI._LAYER_ARRAY_FIELDS) do
	_array_field_set[f] = true
end

local function resolve_field(field)
	local ruleset_key = MPAPI.get_active_ruleset()
	local ruleset = ruleset_key and MPAPI.Rulesets[ruleset_key] or nil
	if _array_field_set[field] then
		local merged = {}
		if ruleset and ruleset[field] then
			for _, v in ipairs(ruleset[field]) do merged[#merged + 1] = v end
		end
		for _, mod_name in ipairs(MPAPI.MODIFIERS) do
			local layer = MPAPI.Layers[mod_name]
			if layer and layer[field] then
				for _, v in ipairs(layer[field]) do merged[#merged + 1] = v end
			end
		end
		return merged
	end
	for i = #MPAPI.MODIFIERS, 1, -1 do
		local layer = MPAPI.Layers[MPAPI.MODIFIERS[i]]
		if layer and layer[field] ~= nil then return layer[field] end
	end
	if ruleset then return ruleset[field] end
	return nil
end

local _resolver = setmetatable({}, {
	__index = function(_, field) return resolve_field(field) end,
})

-- The answer to "what's in the active ruleset?".
-- Safe with no active ruleset: arrays read as {}, the rest as nil.
function MPAPI.current_ruleset()
	return _resolver
end

-----------------------------
-- Ban application
-----------------------------

function MPAPI.ApplyBans()
	local ruleset_key = MPAPI.get_active_ruleset()
	local gamemode_key = MPAPI.get_active_gamemode()
	local gamemode = gamemode_key and MPAPI.GameModes[gamemode_key] or nil

	if not ruleset_key then return end

	local ruleset = MPAPI.current_ruleset()
	local ban_types = { 'jokers', 'consumables', 'vouchers', 'enhancements', 'tags', 'blinds' }
	for _, ban_type in ipairs(ban_types) do
		for _, v in ipairs(ruleset['banned_' .. ban_type]) do
			G.GAME.banned_keys[v] = true
		end
		if gamemode then
			for _, v in ipairs(gamemode['banned_' .. ban_type] or {}) do
				G.GAME.banned_keys[v] = true
			end
		end
	end
	for _, v in ipairs(ruleset.banned_silent) do
		G.GAME.banned_keys[v] = true
	end
end

-----------------------------
-- ReworkCenter + LoadReworks
-----------------------------

local LOADED_REWORKS = {}

-- Register a center stat/behavior patch for specific layer(s).
-- Multiple calls for the same key accumulate — each call targets its own layer slot.
---@param key string  e.g. "j_glass"
---@param opts table  { layers, loc_key?, silent?, center_table?, ...center properties }
function MPAPI.ReworkCenter(key, opts)
	LOADED_REWORKS[key] = LOADED_REWORKS[key] or {}
	table.insert(LOADED_REWORKS[key], opts or {})
end

-- Hook SMODS.injectItems to store vanilla + reworked variants on each center at load time.
local _inject_ref = SMODS.injectItems
function SMODS.injectItems()
	local ret = _inject_ref()
	for key, opts_list in pairs(LOADED_REWORKS) do
		for _, opts in ipairs(opts_list) do
			local center_table = (type(opts.center_table) == 'table' and opts.center_table)
				or G[opts.center_table]
				or G.P_CENTERS
			local center = center_table[key]
			if not center then
				MPAPI.sendWarnMessage('[ruleset] ReworkCenter: unknown center key: ' .. tostring(key))
				goto continue
			end

			local reserved = { layers = true, loc_key = true, silent = true, center_table = true }
			local layers = opts.layers
			local loc_key = opts.loc_key
			local silent = opts.silent

			if type(layers) == 'string' then layers = { layers } end

			if loc_key then
				local user_loc_vars = opts.loc_vars or function() return {} end
				opts.loc_vars = function(self, info_queue, card)
					local result = user_loc_vars(self, info_queue, card)
					result.key = loc_key
					return result
				end
			end

			local needs_generate_ui = opts.loc_vars
				and not opts.generate_ui
				and not (center.generate_ui and type(center.generate_ui) == 'function')

			if center.config then
				opts.config = opts.config or copy_table(center.config)
				opts.config.mp_balanced = true
			end

			for _, layer in ipairs(layers) do
				local prefix = 'mp_' .. layer .. '_'
				for k, v in pairs(opts) do
					if not reserved[k] then
						center[prefix .. k] = v
						if not center['mp_vanilla_' .. k] then
							center['mp_vanilla_' .. k] = center[k] or 'NULL'
						end
					end
				end
				if needs_generate_ui then
					center[prefix .. 'generate_ui'] = SMODS.Center.generate_ui
					if not center.mp_vanilla_generate_ui then
						center.mp_vanilla_generate_ui = center.generate_ui or 'NULL'
					end
				end
				center.mp_reworks = center.mp_reworks or {}
				center.mp_reworks[layer] = true
				center.mp_reworks['vanilla'] = true
				center.mp_silent = center.mp_silent or {}
				center.mp_silent[layer] = silent
			end

			::continue::
		end
	end
	return ret
end

-- Apply the rework chain for the given ruleset key (or "vanilla" to reset).
-- Resolves via active_layer_chain: vanilla pass first, then layers in order.
-- Optionally restrict to a single center key.
function MPAPI.LoadReworks(ruleset_key, key)
	ruleset_key = ruleset_key or 'vanilla'

	local function process(center_key, prefix, tbl)
		local center = tbl[center_key]
		if not center then return end
		for k, v in pairs(center) do
			if string.sub(k, 1, #prefix) == prefix then
				local orig = string.sub(k, #prefix + 1)
				if orig == 'rarity' then
					SMODS.remove_pool(G.P_JOKER_RARITY_POOLS[center[orig]], center.key)
					table.insert(G.P_JOKER_RARITY_POOLS[center[k]], center)
					table.sort(G.P_JOKER_RARITY_POOLS[center[k]], function(a, b) return a.order < b.order end)
				end
				center[orig] = (center[k] == 'NULL') and nil or center[k]
			end
		end
	end

	local resolution = MPAPI.active_layer_chain(ruleset_key)

	local tables = { G.P_CENTERS, G.P_TAGS, G.P_SEALS, SMODS.PokerHands, G.P_STAKES, G.P_BLINDS }

	if key then
		for _, tbl in ipairs(tables) do
			if tbl[key] then
				process(key, 'mp_vanilla_', tbl)
				for _, layer in ipairs(resolution) do process(key, 'mp_' .. layer .. '_', tbl) end
				break
			end
		end
	else
		for _, tbl in ipairs(tables) do
			for k, v in pairs(tbl) do
				if v.mp_reworks then
					if v.mp_reworks['vanilla'] then process(k, 'mp_vanilla_', tbl) end
					for _, layer in ipairs(resolution) do
						if v.mp_reworks[layer] then process(k, 'mp_' .. layer .. '_', tbl) end
					end
				end
			end
		end
	end
end

-----------------------------
-- Game:start_run hook
-----------------------------

local _start_run_ref = Game.start_run
function Game:start_run(args)
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	local ruleset_key = lobby and lobby:get_metadata().ruleset or nil
	MPAPI.LoadReworks(ruleset_key)
	return _start_run_ref(self, args)
end
