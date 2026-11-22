-- Shared helpers for the API tests. Every test runs from the MPAPI repository root:
-- luajit tests/<name>_test.lua
local T = { checks = 0 }

function T.check(condition, message)
	T.checks = T.checks + 1
	assert(condition, message)
end

function T.eq(got, want, what)
	T.check(got == want, what .. ': got ' .. tostring(got) .. ', want ' .. tostring(want))
end

function T.done(name)
	print(('%s: %d checks passed'):format(name, T.checks))
end

-- Runs fn on the globals as they were before it, so the parts of one test file stay as
-- independent as separate files: every global, package.loaded and package.preload come back.
local function copy(t)
	local c = {}
	for k, v in pairs(t) do
		c[k] = v
	end
	return c
end
local function restore(t, saved)
	for k in pairs(t) do
		if saved[k] == nil then t[k] = nil end
	end
	for k, v in pairs(saved) do
		t[k] = v
	end
end
function T.part(fn)
	local globals, loaded, preload = copy(_G), copy(package.loaded), copy(package.preload)
	fn()
	restore(_G, globals)
	restore(package.loaded, loaded)
	restore(package.preload, preload)
end

-- The MPAPI stub the lobby tests load api/lobby/*.lua into. `extra` fields are added on top.
function T.lobby_mpapi(extra)
	local M = {
		_internal = {},
		load_mpapi_file = function() end,
		ActionType = setmetatable({ obj_buffer = {} }, { __call = function() end }),
		ActionTypes = {},
		get_current_lobby = function() end,
		LobbyEvent = setmetatable({}, { __index = function(_, k) return k end }),
		networking = { nakama_lobby = { set_grace_seconds = function() end } },
		sendWarnMessage = function() end,
		sendDebugMessage = function() end,
	}
	for k, v in pairs(extra or {}) do
		M[k] = v
	end
	return M
end

return T
