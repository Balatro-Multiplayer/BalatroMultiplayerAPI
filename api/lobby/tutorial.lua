-- A profile that never finished Balatro's tutorial gets a different run: the
-- first shop is forced to Joker and The Empress, the first voucher to Grabber,
-- the ante 1 tags to Handy and Garbage, and every pack in that first shop costs
-- $3 more (card.lua set_cost_value). In a lobby everyone plays the same seed, so
-- that player's run no longer matches the others'. A lobby run counts the
-- tutorial as done first, as the base game's own skip does (G.F_SKIP_TUTORIAL).
MPAPI._internal.tutorial = MPAPI._internal.tutorial or {}
local T = MPAPI._internal.tutorial

-- Marks the tutorial done in settings; true when that changed anything.
function T.skip(settings)
	if settings.tutorial_complete and settings.tutorial_progress == nil then return false end
	settings.tutorial_complete = true
	settings.tutorial_progress = nil
	return true
end

local start_run_ref = Game.start_run
function Game:start_run(args)
	if MPAPI.get_current_lobby and MPAPI.get_current_lobby() then T.skip(G.SETTINGS) end
	return start_run_ref(self, args)
end
