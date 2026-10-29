-- Contract tests, not a game simulator. Run from the MPAPI repository root.
--
-- A layer's calculate hook belongs to the layer. MPAPI.resolve_layers must not
-- copy it onto the ruleset: MPAPI.calculate_context already runs every layer
-- in the active chain and then the ruleset itself, so a copied hook ran twice
-- per event -- for apply_bans, Small World's 75% cull re-culled its own
-- survivors. Same for pool_enabled (pool gating asks each owning layer).
-- Functions only ever read off the ruleset (force_lobby_options, is_disabled)
-- must keep flowing layer -> ruleset.
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

MPAPI = {}
dofile('api/layers/registry.lua')
dofile('api/layers/fields.lua')
dofile('api/layers/chain.lua')
dofile('api/context/dispatch.lua')

MPAPI.MODIFIERS = {}
MPAPI.Rulesets = {}
MPAPI._handle_gamemode_result = function() end
MPAPI.get_current_lobby = function()
	return nil
end
local active_key
MPAPI.get_active_ruleset = function()
	return active_key
end

local calls = {}
local function hook(name)
	return function(self, context)
		if context.apply_bans then
			calls[#calls + 1] = name
		end
	end
end
local function pool_enabled()
	return true
end

MPAPI.Layer('base', { multiplayer_content = true, banned_jokers = { 'j_a' } })
MPAPI.Layer('culls', { calculate = hook('culls'), pool_enabled = pool_enabled })
MPAPI.Layer('idol', { calculate = hook('idol') })
MPAPI.Layer('timer', { timer = true })
local function forced(self)
	return true
end
MPAPI.Layer('ranked', { forced_lobby_options = true, force_lobby_options = forced })

local function ruleset(key, layers)
	local init = MPAPI.resolve_layers({ key = key, layers = layers })
	MPAPI.Rulesets[key] = init
	return init
end
local last = ruleset('r_last', { 'base', 'culls' })
local middle = ruleset('r_middle', { 'base', 'idol', 'culls', 'timer' })
local none = ruleset('r_none', { 'base' })
local own = ruleset('r_own', { 'base', 'culls' })
local ranked = ruleset('r_ranked', { 'base', 'ranked' })
own.calculate = hook('r_own')

-- Non-function scalars still flow layer -> ruleset (last layer wins).
check(last.multiplayer_content == true, 'scalar copied from a layer')
check(middle.timer == true, 'scalar copied from the last layer')
check(#last.banned_jokers == 1 and last.banned_jokers[1] == 'j_a', 'array fields concatenated')

-- Functions the ruleset is read for (not dispatched through the chain) still flow.
check(ranked.force_lobby_options == forced, 'force_lobby_options copied from a layer')
check(ranked.forced_lobby_options == true, 'its flag copied too')

-- Chain-dispatched hooks do not.
check(last.calculate == nil, 'calculate not copied when the hook layer is last')
check(middle.calculate == nil, 'calculate not copied when a hookless layer is last')
check(last.pool_enabled == nil, 'pool_enabled not copied')
check(none.calculate == nil, 'no hook on a ruleset with no hook layers')

local function dispatch(key)
	calls = {}
	active_key = key
	MPAPI.calculate_context({ apply_bans = true })
	return table.concat(calls, ',')
end

check(dispatch('r_last') == 'culls', 'hook layer last: runs once, got ' .. dispatch('r_last'))
check(dispatch('r_middle') == 'idol,culls', 'hook layers in the middle: each once, got ' .. dispatch('r_middle'))
check(dispatch('r_none') == '', 'no hook layers: nothing runs')
check(dispatch('r_own') == 'culls,r_own', "a ruleset's own calculate still runs after its layers, got " .. dispatch('r_own'))

print('OK: ' .. checks .. ' checks')
