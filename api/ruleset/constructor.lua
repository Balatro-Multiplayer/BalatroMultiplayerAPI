-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the ruleset system this is based on.
-- Ruleset construction: resolves declared layers into the init table, registers
-- the ruleset, and exposes it as a P_CENTER pool.
G.P_CENTER_POOLS.Ruleset = G.P_CENTER_POOLS.Ruleset or {}
MPAPI.Rulesets = MPAPI.Rulesets or {}

local RulesetMeta = {}
RulesetMeta.__index = RulesetMeta

function RulesetMeta:inject()
	MPAPI.Rulesets[self.key] = self
	if not G.P_CENTER_POOLS.Ruleset then G.P_CENTER_POOLS.Ruleset = {} end
	table.insert(G.P_CENTER_POOLS.Ruleset, self)
end

function RulesetMeta:is_disabled()
	return false
end

function RulesetMeta:force_lobby_options()
	return false
end

-- Reworked entries defined directly on the ruleset need reverse-index entries;
-- entries pulled in from layers are already indexed when MPAPI.Layer() was called.
local function index_ruleset_reworks(init)
	local function index_list(list, index_table)
		if not list then return end
		for _, key in ipairs(list) do
			index_table[key] = index_table[key] or {}
			table.insert(index_table[key], init.key)
		end
	end
	index_list(init.reworked_jokers, MPAPI._JOKER_LAYERS)
	index_list(init.reworked_consumables, MPAPI._CONSUMABLE_LAYERS)
	index_list(init.reworked_tags, MPAPI._TAG_LAYERS)
end

function MPAPI.Ruleset(init)
	assert(type(init) == 'table' and init.key, 'MPAPI.Ruleset: key is required')
	init = MPAPI.resolve_layers(init)
	index_ruleset_reworks(init)
	return setmetatable(init, RulesetMeta)
end
