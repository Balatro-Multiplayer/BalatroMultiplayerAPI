-- Contract tests, not a game simulator. Run from the MPAPI repository root.
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local messages = {}
MPAPI = {
	sendDebugMessage = function(message)
		messages[#messages + 1] = message
	end,
}
SMODS = {}
for _, kind in ipairs({ 'Joker', 'Consumable', 'Tag', 'Voucher', 'Enhancement', 'Blind' }) do
	SMODS[kind] = {
		register = function(self)
			self.registered = true
		end,
	}
end

dofile('api/layers/registry.lua')
dofile('api/layers/fields.lua')
dofile('api/layers/chain.lua')
dofile('api/layers/modifiers.lua')
dofile('api/layers/pool_gating.lua')
dofile('api/ruleset/current.lua')

MPAPI.Rulesets = {}
local active_key
MPAPI.get_active_ruleset = function()
	return active_key
end

local categories = {
	{ field = 'jokers', kind = 'Joker', prefix = 'j' },
	{ field = 'consumables', kind = 'Consumable', prefix = 'c' },
	{ field = 'tags', kind = 'Tag', prefix = 'tag' },
	{ field = 'vouchers', kind = 'Voucher', prefix = 'v' },
	{ field = 'enhancements', kind = 'Enhancement', prefix = 'm' },
	{ field = 'blinds', kind = 'Blind', prefix = 'bl' },
}

local definition, centers = {}, {}
for _, category in ipairs(categories) do
	local key = category.prefix .. '_test_original'
	definition['included_' .. category.field] = { key }
	centers[category.field] = { key = key }
end
MPAPI.Layer('originals', definition)
MPAPI.Layer('reworks', { reworked_jokers = { 'j_test_rework' } })
MPAPI.Layer('both', { included_jokers = { 'j_test_original' } })

MPAPI.Rulesets.with = MPAPI.resolve_layers({ key = 'with', layers = { 'originals', 'reworks' } })
MPAPI.Rulesets.without = MPAPI.resolve_layers({ key = 'without' })
for _, category in ipairs(categories) do
	local center = centers[category.field]
	SMODS[category.kind].register(center)
	check(center.registered and type(center.mp_include) == 'function', category.field .. ' auto-gated')
	check(MPAPI.Rulesets.with['included_' .. category.field][1] == center.key, category.field .. ' composed')
	check(#MPAPI.Rulesets.without['included_' .. category.field] == 0, category.field .. ' defaults empty')
	active_key = 'with'
	check(not MPAPI.should_exclude_from_pool(center), category.field .. ' included with layer')
	active_key = 'without'
	check(MPAPI.should_exclude_from_pool(center), category.field .. ' excluded without layer')
end

local rework = { key = 'j_test_rework' }
SMODS.Joker.register(rework)
active_key = 'with'
check(not MPAPI.should_exclude_from_pool(rework), 'reworked membership unchanged')
active_key = 'without'
check(MPAPI.should_exclude_from_pool(rework), 'inactive rework excluded')
MPAPI.add_modifier('originals')
check(not MPAPI.should_exclude_from_pool(centers.jokers), 'modifier includes original')
check(MPAPI.current_ruleset().included_jokers[1] == centers.jokers.key, 'modifier appears in read model')
MPAPI.remove_modifier('originals')

-- Any owning layer may include a card, including one registered after the card.
MPAPI.Layer('late_owner', { included_jokers = { 'j_test_original' } })
MPAPI.Rulesets.late = MPAPI.resolve_layers({ key = 'late', layers = { 'originals', 'late_owner' } })
active_key = 'late'
check(not MPAPI.should_exclude_from_pool(centers.jokers), 'additional owner is visible after registration')

-- A modifier can switch off a layer the ruleset composes.
MPAPI.Layer('no_originals', { removes_layers = { 'originals' } })
active_key = 'with'
MPAPI.add_modifier('no_originals')
check(not MPAPI.is_layer_active('originals'), 'removed layer leaves the chain')
check(MPAPI.is_layer_active('reworks'), 'other layers stay in the chain')
check(MPAPI.should_exclude_from_pool(centers.consumables), 'removed layer no longer includes its cards')
check(not MPAPI.should_exclude_from_pool(rework), 'other layers keep their cards')
check(MPAPI.current_ruleset().included_consumables[1] == centers.consumables.key, 'baked fields stay in the read model')
MPAPI.add_modifier('originals')
check(not MPAPI.is_layer_active('originals'), 'removal wins over a modifier adding the same layer')
MPAPI.remove_modifier('originals')
active_key = 'late'
check(not MPAPI.should_exclude_from_pool(centers.jokers), 'another active owner still includes the card')
check(MPAPI.should_exclude_from_pool(centers.consumables), 'cards owned only by the removed layer are excluded')
MPAPI.remove_modifier('no_originals')
check(not MPAPI.should_exclude_from_pool(centers.consumables), 'dropping the modifier restores the layer')
MPAPI.Rulesets.static_removal = MPAPI.resolve_layers({ key = 'static_removal', layers = { 'originals', 'no_originals' } })
active_key = 'static_removal'
check(MPAPI.is_layer_active('originals'), 'only modifiers remove layers')
active_key = 'with'

MPAPI.register_mod_isolation('test', function()
	return false
end)
local explicit = {
	key = 'j_test_original',
	mod = { id = 'test' },
	mp_include = function()
		return false
	end,
}
SMODS.Joker.register(explicit)
check(MPAPI.should_exclude_from_pool(explicit), 'bespoke exclusion wins over layer')
explicit.mp_include = function()
	return true
end
check(not MPAPI.should_exclude_from_pool(explicit), 'bespoke inclusion wins over isolation')
check(MPAPI.should_exclude_from_pool({ key = 'j_test_unlisted', mod = { id = 'test' } }), 'unlisted content isolated')
check(#MPAPI.Rulesets.with.reworked_jokers == 1, 'original content is not presented as reworked')

local function warning_count()
	local count = 0
	for _, message in ipairs(messages) do
		if message:match('^WARNING: ') then
			count = count + 1
		end
	end
	return count
end

-- Warn by isolated owner, not the consumer's choice of key prefix. Do not
-- evaluate its runtime gate while registering cards at boot.
MPAPI.register_mod_isolation('consumer', function()
	error('registration must not evaluate the gate')
end)
for _, category in ipairs(categories) do
	local count = warning_count()
	local key = category.prefix .. '_consumer_unlisted'
	SMODS[category.kind].register({ key = key, mod = { id = 'consumer' } })
	check(warning_count() == count + 1, category.field .. ' warns for an unlisted isolated consumer')
	check(messages[#messages]:find(key, 1, true) ~= nil, category.field .. ' warning identifies the card')
end
MPAPI.register_mod_isolation('permissive_consumer', function()
	return true
end)
local count = warning_count()
SMODS.Joker.register({ key = 'j_permissive_unlisted', mod = { id = 'permissive_consumer' } })
check(warning_count() == count + 1, 'warn even when isolation currently admits unowned content')
count = warning_count()
SMODS.Joker.register({ key = 'j_test_original', mod = { id = 'consumer' } })
check(warning_count() == count, 'layer-owned consumer card does not warn')
SMODS.Joker.register({
	key = 'j_consumer_bespoke',
	mod = { id = 'consumer' },
	mp_include = function()
		return false
	end,
})
check(warning_count() == count, 'bespoke consumer gate does not warn')
SMODS.Joker.register({ key = 'j_unrelated_original', mod = { id = 'unrelated' } })
check(warning_count() == count, 'ordinary unrelated mod does not warn')
SMODS.Joker.register({ key = 'j_mpapi_unlisted' })
check(warning_count() == count + 1, 'legacy MPAPI-prefix warning remains available without mod metadata')
local permissive = { key = 'j_permissive_unlisted', mod = { id = 'permissive_consumer' } }
check(not MPAPI.should_exclude_from_pool(permissive), 'warning does not change the isolation policy')

print(('Layer content contracts: %d checks passed'):format(checks))
