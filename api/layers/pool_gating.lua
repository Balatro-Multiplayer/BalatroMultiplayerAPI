-- Decides which centers appear in the active ruleset's pools, and hooks SMODS
-- registration so cards gated only by layer membership are auto-attached an
-- mp_include closure under default-deny.
MPAPI._JOKER_LAYERS = MPAPI._JOKER_LAYERS or {}
MPAPI._CONSUMABLE_LAYERS = MPAPI._CONSUMABLE_LAYERS or {}
MPAPI._TAG_LAYERS = MPAPI._TAG_LAYERS or {}
MPAPI._VOUCHER_LAYERS = MPAPI._VOUCHER_LAYERS or {}
MPAPI._ENHANCEMENT_LAYERS = MPAPI._ENHANCEMENT_LAYERS or {}
MPAPI._BLIND_LAYERS = MPAPI._BLIND_LAYERS or {}

local function layer_membership_include(owning_layers)
	return function(_)
		return MPAPI.is_any_layer_active(owning_layers)
	end
end

-- Mod-content isolation: a consuming mod (PvP, Speedrun, or any future MPAPI
-- consumer) registers ONCE how to tell whether its own custom pool content should
-- be active right now, instead of every individual joker/consumable/voucher/tag
-- hand-writing the same closure. should_exclude_from_pool below then applies this
-- automatically to any object tagged with that mod's id (SMODS already sets
-- v.mod.id on every registered center -- no naming-convention guesswork needed).
MPAPI._mod_isolation_gates = MPAPI._mod_isolation_gates or {}

function MPAPI.register_mod_isolation(mod_id, is_active_fn)
	MPAPI._mod_isolation_gates[mod_id] = is_active_fn
end

-- Public so an object needing bespoke mp_include logic beyond its mod's default
-- (e.g. an extra layer exclusion) can still build on the shared per-mod gate
-- instead of re-deriving "is my mod's content active" by hand.
function MPAPI.mod_isolation_active(mod_id)
	local gate = MPAPI._mod_isolation_gates[mod_id]
	return gate ~= nil and gate() or false
end

function MPAPI.should_exclude_from_pool(v)
	-- Explicit per-object override always wins first (escape hatch for bespoke logic).
	if v.mp_include and type(v.mp_include) == 'function' then return not v:mp_include() end
	-- Mod-level default: exclude unless the owning mod's own content is active right now.
	local owner = v.mod and v.mod.id
	local gate = owner and MPAPI._mod_isolation_gates[owner]
	if gate then return not gate() end
	-- Last-resort safety net for objects from an isolated mod with no .mod set.
	if v.key and v.key:match('^%a+_mp_') then return true end
	return false
end

local function warn_if_ungated(key, kind, prefix)
	if key and key:sub(1, #prefix) == prefix then
		MPAPI.sendDebugMessage(
			'WARNING: '
				.. kind
				.. ' '
				.. key
				.. ' has no mp_include and is not in any reworked list. '
				.. 'Under default-deny it will be excluded from every ruleset pool. '
				.. 'Either add the key to a layer/ruleset reworked_'
				.. kind
				.. 's, or define an explicit mp_include.'
		)
	end
end

local function auto_gate_on_register(self, index_table, kind, ungated_prefix)
	if not self.mp_include and index_table[self.key] then
		local owning_layers = index_table[self.key]
		MPAPI.sendDebugMessage('Auto-gating ' .. self.key .. ' on layers: ' .. table.concat(owning_layers, ', '))
		self.mp_include = layer_membership_include(owning_layers)
	end
	if not self.mp_include then warn_if_ungated(self.key, kind, ungated_prefix) end
end

local _original_joker_register = SMODS.Joker.register
function SMODS.Joker:register()
	auto_gate_on_register(self, MPAPI._JOKER_LAYERS, 'joker', 'j_mpapi_')
	return _original_joker_register(self)
end

local _original_consumable_register = SMODS.Consumable.register
function SMODS.Consumable:register()
	auto_gate_on_register(self, MPAPI._CONSUMABLE_LAYERS, 'consumable', 'c_mpapi_')
	return _original_consumable_register(self)
end

local _original_tag_register = SMODS.Tag.register
function SMODS.Tag:register()
	auto_gate_on_register(self, MPAPI._TAG_LAYERS, 'tag', 'tag_mpapi_')
	return _original_tag_register(self)
end

-- §9.4: Vouchers and Enhancements share get_current_pool() with Jokers/
-- Consumables (vanilla's own function, patched above), so the same
-- mp_include auto-attach closes the gap for them with no new patch needed.
local _original_voucher_register = SMODS.Voucher.register
function SMODS.Voucher:register()
	auto_gate_on_register(self, MPAPI._VOUCHER_LAYERS, 'voucher', 'v_mpapi_')
	return _original_voucher_register(self)
end

local _original_enhancement_register = SMODS.Enhancement.register
function SMODS.Enhancement:register()
	auto_gate_on_register(self, MPAPI._ENHANCEMENT_LAYERS, 'enhancement', 'm_mpapi_')
	return _original_enhancement_register(self)
end

-- Blinds are NOT gated through get_current_pool() at all -- boss selection is
-- vanilla's separate get_new_boss(), patched in lovely/pool_gating.toml to
-- also drop any blind whose owning layer isn't active, alongside its existing
-- G.GAME.banned_keys filter (explicit banned_blinds already worked before
-- this, since get_new_boss checks banned_keys natively; this only adds the
-- layer-membership half auto_gate_on_register gives every other content type).
local _original_blind_register = SMODS.Blind.register
function SMODS.Blind:register()
	auto_gate_on_register(self, MPAPI._BLIND_LAYERS, 'blind', 'bl_mpapi_')
	return _original_blind_register(self)
end
