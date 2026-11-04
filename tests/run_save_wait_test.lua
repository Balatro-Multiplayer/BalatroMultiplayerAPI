-- The Run save of a Blind Select waits behind the events ahead of it, as vanilla's own save of
-- that screen does. A deck that adds its starting cards in a delayed event (the Ghost Deck's Hex)
-- has them only after that delay, and a Run save taken before it lacks them.
-- Run from the MPAPI repository root: luajit tests/run_save_wait_test.lua
local added = {}
Event = function(opts)
	return opts
end
G = {
	STATE_COMPLETE = false,
	E_MANAGER = {
		add_event = function(_, event)
			added[#added + 1] = event
		end,
	},
}
Game = {
	update_blind_select = function()
		G.STATE_COMPLETE = true
	end,
}
MPAPI = { _internal = {}, replay = {}, sendWarnMessage = function() end }
dofile('api/replay/run_save.lua')

Game:update_blind_select(0.1)
assert(#added == 1, 'the screen build queues one Run save event, got ' .. #added)
assert(added[1].blockable ~= false, 'the Run save event can be blocked by the events ahead of it')
assert(added[1].trigger == 'immediate', 'and it runs as soon as they are done')
Game:update_blind_select(0.1)
assert(#added == 1, 'a screen that is already built queues none')
print('run_save_wait_test: ok')
