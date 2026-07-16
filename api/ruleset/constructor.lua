-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the ruleset system this is based on.
-- Ruleset construction: resolves declared layers into the init table, then
-- registers as a real SMODS.GameObject -- gets dupe-key checking and
-- required_params validation for free, matching MPAPI.GameMode/ActionType.
-- `inject` (the G.P_CENTER_POOLS.Ruleset registration) is called automatically
-- by SMODS's own boot-time injection sweep; ruleset definitions must NOT call
-- `:inject()` themselves anymore (that would double-register).
MPAPI.Rulesets = MPAPI.Rulesets or {}

-- Reworked entries defined directly on the ruleset need reverse-index entries;
-- entries pulled in from layers are already indexed when MPAPI.Layer() was called.
-- Must run synchronously at construction time, not inside `inject` (which SMODS
-- defers to its boot-time sweep) -- pool_gating.lua's auto-gate-on-register check
-- reads these indices the moment each Joker/Consumable/Tag registers, which can
-- happen well before the deferred sweep runs.
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

local RulesetBase = SMODS.GameObject:extend({
	obj_table = MPAPI.Rulesets,
	obj_buffer = {},
	set = 'Ruleset',
	required_params = { 'key' },

	is_disabled = function(self)
		return false
	end,

	force_lobby_options = function(self)
		return false
	end,

	inject = function(self)
		G.P_CENTER_POOLS.Ruleset = G.P_CENTER_POOLS.Ruleset or {}
		table.insert(G.P_CENTER_POOLS.Ruleset, self)
	end,
})

function MPAPI.Ruleset(init)
	assert(type(init) == 'table' and init.key, 'MPAPI.Ruleset: key is required')
	init = MPAPI.resolve_layers(init)
	index_ruleset_reworks(init)
	return RulesetBase(init)
end
