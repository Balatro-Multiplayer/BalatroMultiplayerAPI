MPAPI.ActionTypes = {}

-- `authoritative = true`: the server runs the action instead of relaying it
-- (BalatroMultiplayerServer nakama/src/actions/registry.ts). Only MPAPI's own
-- action types can be authoritative -- they're the only ones the server has
-- a handler for -- so a mod's actions are always relayed and the server never
-- needs to know about them. Authoritative actions need a Nakama lobby.
MPAPI.ActionType = SMODS.GameObject:extend {
	obj_table = MPAPI.ActionTypes,
	obj_buffer = {},
	set = 'ActionType',
	required_params = { 'key', 'on_receive' },

	register = function(self)
		if self.authoritative and not (self.mod and self.mod.id == MPAPI.id) then
			MPAPI.sendWarnMessage('ActionType ' .. tostring(self.key) .. ': authoritative actions are MPAPI-only; it will be relayed')
			self.authoritative = false
		end
		MPAPI.ActionType.super.register(self)
	end,

	inject = function(self) end,  -- obj_table is the registry, no game tables needed
}
