-- Contract test: a Run save is taken at the save points (lovely/run_save_points.toml calls
-- MPAPI.run_save.at_save_point() right after vanilla's save_run there) and nowhere else.
-- Each case below runs the code of one patched site as the Lovely patch leaves it.
-- Run from the MPAPI repository root: luajit tests/run_save_points_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local sent = {}
local lobby = {
	mod_id = 'demo_mod',
	_game = { started = { run_id = 'RUN1' } },
	action = function()
		return {
			send = function(_, _, params)
				sent[#sent + 1] = params
				return true
			end,
		}
	end,
}
local shop_built = false
MPAPI = {
	_internal = {},
	ActionTypes = { mpapi_run_save_part = 'PART_TYPE' },
	replay = {
		_card_ids = {},
		_next_card_id = 1,
		log_position = function()
			return 3, string.rep('ab', 32)
		end,
	},
	playback = {
		_rejoin_hooks = { demo_mod = { run_save_screens = { SHOP = true } } },
		shop_is_built = function()
			return shop_built
		end,
	},
	get_current_lobby = function()
		return lobby
	end,
	has_server_referee = function()
		return true
	end,
	sendDebugMessage = function() end,
	sendWarnMessage = function(msg)
		error('unexpected warning: ' .. tostring(msg))
	end,
}
G = {
	STATES = { SELECTING_HAND = 1, SHOP = 5, BLIND_SELECT = 7 },
	F_NO_SAVING = true,
	ARGS = {},
	FILE_HANDLER = {},
	GAME = { dollars = 4, tags = {} },
}

-- Vanilla's save_run: the table it builds, unless saving is off.
local function vanilla_save_run()
	if G.F_NO_SAVING then
		return
	end
	G.ARGS.save_run = { STATE = G.STATE, GAME = { dollars = G.GAME.dollars, tags = #G.GAME.tags }, cardAreas = {} }
end
-- PvP's wrapper (overrides/game.lua) sits outside and returns first while saving is off.
local wrapper_returned_early = 0
function save_run()
	if G.F_NO_SAVING then
		wrapper_returned_early = wrapper_returned_early + 1
		return
	end
	return vanilla_save_run()
end

dofile('api/replay/run_save.lua')
local RS = MPAPI.run_save
local packed = {}
RS.codec = {
	pack = function(value)
		packed[#packed + 1] = value
		return 'P'
	end,
	compress = function(text)
		return text
	end,
	to_text = function(text)
		return text
	end,
}
local function reset()
	sent, packed, wrapper_returned_early = {}, {}, 0
end

-- The shop build site (game.lua, Game:update_shop), as patched.
local function shop_build_site(nosave_shop)
	if not nosave_shop then
		save_run()
		MPAPI.run_save.at_save_point()
	end
end

-- 1. The shop build of a mod that declares SHOP takes exactly one save, under PvP's wrapper.
G.STATE, shop_built = G.STATES.SHOP, true
reset()
shop_build_site(false)
check(#packed == 1 and #sent == 1, 'the shop build takes one save, got ' .. #packed)
check(packed[1].save.STATE == G.STATES.SHOP, 'the save is of the shop')
check(wrapper_returned_early == 1, "vanilla's own save_run returned early in the lobby")
check(G.F_NO_SAVING == true, 'saving is off again after the take')

-- 2. A save_run from anywhere else (PvP's run snapshot clears the flag and calls save_run) takes none.
reset()
G.F_NO_SAVING = false
save_run()
G.F_NO_SAVING = true
check(#sent == 0 and #packed == 0, 'a direct save_run takes no Run save')

-- 3. A shop loaded from a save has no save_run at its build, so no Run save.
reset()
shop_build_site(true)
check(#sent == 0, 'a loaded shop takes no save')

-- 4. A shop that is not built yet takes none.
shop_built = false
reset()
shop_build_site(false)
check(#sent == 0, 'a shop without its starting cards takes no save')
shop_built = true

-- 5. A mod that does not declare SHOP gets no shop save; Blind Select is still saved.
MPAPI.playback._rejoin_hooks.demo_mod = { run_save_screens = { BLIND_SELECT = true } }
reset()
shop_build_site(false)
check(#sent == 0, 'no SHOP save for a mod that does not declare it')
MPAPI.playback._rejoin_hooks.demo_mod = nil
reset()
shop_build_site(false)
check(#sent == 0, 'no SHOP save for a mod with no rejoin hooks')
G.STATE = G.STATES.BLIND_SELECT
reset()
save_run()
MPAPI.run_save.at_save_point()
check(#sent == 1 and packed[1].save.STATE == G.STATES.BLIND_SELECT, 'Blind Select is saved without a declaration')
MPAPI.playback._rejoin_hooks.demo_mod = { run_save_screens = { SHOP = true } }

-- 6. The skip site (G.FUNCS.skip_blind), as patched: the save holds the tag, its effect not applied.
local function apply_tag()
	G.GAME.dollars = G.GAME.dollars + 25
end
G.GAME.dollars, G.GAME.tags = 4, {}
reset()
G.GAME.tags[#G.GAME.tags + 1] = { apply = apply_tag }
save_run()
MPAPI.run_save.at_save_point()
for i = 1, #G.GAME.tags do
	G.GAME.tags[i].apply()
end
check(#packed == 1, 'the skip takes one save')
check(packed[1].save.GAME.tags == 1, 'the skip save holds the tag')
check(packed[1].save.GAME.dollars == 4 and G.GAME.dollars == 29, "the tag's effect is not in the save")

-- 7. Any other screen is no save point, and no lobby means no save.
G.STATE = G.STATES.SELECTING_HAND
reset()
MPAPI.run_save.at_save_point()
check(#sent == 0, 'no save while a hand is being played')
G.STATE = G.STATES.BLIND_SELECT
local real_lobby = lobby
lobby = nil
reset()
MPAPI.run_save.at_save_point()
check(#sent == 0, 'no save outside a lobby')
lobby = real_lobby

-- 8. A lobby catching up takes none.
lobby._catching_up = true
reset()
MPAPI.run_save.at_save_point()
check(#sent == 0, 'no save while the lobby is catching up')
lobby._catching_up = false

print(string.format('run_save_points_test: %d checks passed', checks))
