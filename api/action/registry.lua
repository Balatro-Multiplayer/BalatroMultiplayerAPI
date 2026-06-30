MPAPI.ActionTypes = {}

MPAPI.ActionType = SMODS.GameObject:extend {
	obj_table = MPAPI.ActionTypes,
	obj_buffer = {},
	set = 'ActionType',
	required_params = { 'key', 'on_receive' },

	inject = function(self) end,  -- obj_table is the registry, no game tables needed
}
