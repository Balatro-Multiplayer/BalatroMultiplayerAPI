-- Credit to @MathIsFun_ and the Balatro Multiplayer project for the ruleset system this is based on.
-- Ruleset construction: resolves declared layers into the init table, then
-- registers as a real SMODS.GameObject -- gets dupe-key checking and
-- required_params validation for free, matching MPAPI.GameMode/ActionType.
-- `inject` (the G.P_CENTER_POOLS.Ruleset registration) is called automatically
-- by SMODS's own boot-time injection sweep; ruleset definitions must NOT call
-- `:inject()` themselves anymore (that would double-register).
--
-- §9.2: a ruleset is purely a named bundle of layers now -- it no longer
-- declares banned_*/reworked_* directly, so there's no longer a separate
-- reverse-index step needed here. Every reworked entry is indexed once, by
-- MPAPI.Layer() itself, when the owning layer registers.
MPAPI.Rulesets = MPAPI.Rulesets or {}

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
	return RulesetBase(init)
end
