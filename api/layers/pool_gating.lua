-- Decides which centers appear in the active ruleset's pools, and hooks SMODS
-- registration so cards gated only by layer membership are auto-attached an
-- mp_include closure under default-deny.
MPAPI._JOKER_LAYERS = MPAPI._JOKER_LAYERS or {}
MPAPI._CONSUMABLE_LAYERS = MPAPI._CONSUMABLE_LAYERS or {}
MPAPI._TAG_LAYERS = MPAPI._TAG_LAYERS or {}

local function layer_membership_include(owning_layers)
	return function(_)
		return MPAPI.is_any_layer_active(owning_layers)
	end
end

function MPAPI.should_exclude_from_pool(v)
	if v.mp_include and type(v.mp_include) == 'function' then return not v:mp_include() end
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
