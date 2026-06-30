-- Allowed `type` values for an ActionType parameter schema. These are Lua type
-- names because parameter validation compares against type(value) directly
-- (see api/action/validation.lua).
MPAPI.ActionParamType = {
	STRING = 'string',
	NUMBER = 'number',
	BOOLEAN = 'boolean',
	TABLE = 'table',
}
