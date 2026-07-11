-- MPAPI.Blind / MPAPI.Joker / MPAPI.Consumable: SMODS subclasses carrying the sync mixin,
-- exposed as thin wrapper FUNCTIONS. The wrapper constructs+registers the object normally
-- (so it lands in G.P_BLINDS/G.P_CENTERS and MPAPI.Blinds/Jokers/Consumables with the mixin
-- methods) and then runs framework setup (bus + phantom) while SMODS.current_mod is still the
-- consumer -- so the sync ActionType is owned by the consumer and exists before any lobby.

MPAPI.Blinds = MPAPI.Blinds or {}
MPAPI.Jokers = MPAPI.Jokers or {}
MPAPI.Consumables = MPAPI.Consumables or {}

local function extend_with_mixin(parent, obj_table)
	local t = { obj_table = obj_table, obj_buffer = {} }
	for k, v in pairs(MPAPI._internal.synced_mixin) do
		t[k] = v
	end
	return parent:extend(t)
end

local RawBlind = extend_with_mixin(SMODS.Blind, MPAPI.Blinds)
local RawJoker = extend_with_mixin(SMODS.Joker, MPAPI.Jokers)
local RawConsumable = extend_with_mixin(SMODS.Consumable, MPAPI.Consumables)

local function wrap(RawClass)
	return function(def)
		local obj = RawClass(def)
		MPAPI._internal.on_synced_registered(obj)
		return obj
	end
end

MPAPI.Blind = wrap(RawBlind)
MPAPI.Joker = wrap(RawJoker)
MPAPI.Consumable = wrap(RawConsumable)
