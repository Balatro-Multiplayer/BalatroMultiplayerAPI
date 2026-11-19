-- Avatar display cards must not change the run's used_jokers.
-- Run from the repo root: luajit tests/lobby_info_in_play_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

-- Model card.lua's ownership updates outside overlays; duplicate handling
-- is omitted because these cases use distinct centers.
local CardMeta = {}
CardMeta.__index = CardMeta
function CardMeta:set_ability(center)
	local old = self.config.center
	self.config.center = center
	if not G.OVERLAY_MENU then
		if old then
			G.GAME.used_jokers[old.key] = nil
		end
		G.GAME.used_jokers[center.key] = true
	end
end
function CardMeta:remove()
	self.REMOVED = true
	if not G.OVERLAY_MENU then
		G.GAME.used_jokers[self.config.center.key] = nil
	end
end
function CardMeta:flip() end
function CardMeta:set_debuff() end
function CardMeta:juice_up() end
Card = function(_, _, _, _, _, center)
	local card = setmetatable({ config = {}, states = { drag = {} } }, CardMeta)
	card:set_ability(center)
	return card
end

CardArea = function()
	local area = { cards = {}, T = { x = 0, y = 0, w = 1, h = 1 } }
	function area:emplace(card)
		self.cards[#self.cards + 1] = card
	end
	function area:remove_card(card)
		for i, c in ipairs(self.cards) do
			if c == card then
				table.remove(self.cards, i)
			end
		end
		return card
	end
	function area:remove()
		for _, c in ipairs(self.cards) do
			c:remove()
		end
		self.REMOVED = true
	end
	return area
end

Event = function(args)
	return args
end
G = {
	GAME = { used_jokers = {} },
	P_CENTERS = { j_joker = { key = 'j_joker' }, j_jolly = { key = 'j_jolly' }, j_zany = { key = 'j_zany' }, b_black = { pos = {} } },
	UIT = {},
	C = { UI = {} },
	FUNCS = {},
	ROOM = { T = { x = 0, w = 1, h = 1 } },
	CARD_W = 1,
	CARD_H = 1,
	E_MANAGER = { add_event = function(_, e) e.func() end },
}
localize = function(k) return k end
play_sound = function() end
create_UIBox_generic_options = function(args) return args end

MPAPI = {
	C = {},
	_is_player_debuffed = function() return false end,
	-- Match ui_element:as_overlay: build before setting G.OVERLAY_MENU.
	ui_element = function(build_fn)
		local el = {}
		function el:update() return build_fn() end
		function el:as_overlay()
			build_fn()
			G.OVERLAY_MENU = {}
		end
		return setmetatable(el, { __index = function(_, k) if k == 'node' then return build_fn() end end })
	end,
}

local function new_lobby()
	local handlers = {}
	local lobby = {
		max_players = 2,
		_players = { p1 = { id = 'p1', preferredJoker = 'j_jolly' } },
	}
	function lobby:get_players()
		return { self._players.p1 }
	end
	function lobby:on(name, fn)
		handlers[name] = handlers[name] or {}
		table.insert(handlers[name], fn)
	end
	function lobby:fire(name, ...)
		for _, fn in ipairs(handlers[name] or {}) do
			fn(...)
		end
	end
	return lobby
end

MPAPI.LobbyEvent = { PLAYER_INFO = 'PLAYER_INFO', PLAYER_LEFT = 'PLAYER_LEFT' }
dofile('ui/lobby_card_grid.lua')

-- Late roster events must not re-skin removed cards.
G.OVERLAY_MENU = {}
local lobby = new_lobby()
local grid = MPAPI._new_card_grid()
local _ = grid:build_element(lobby).node
for _, row in ipairs(grid._card_rows) do
	row:remove()
end
G.OVERLAY_MENU = nil
lobby:fire('PLAYER_INFO', 'p1', { preferredJoker = 'j_zany' })
check(not G.GAME.used_jokers.j_zany, 'an avatar change after the overlay closed marks nothing in play')
lobby:fire('PLAYER_LEFT', 'p1')
check(not G.GAME.used_jokers.j_joker, 'a player leaving after the overlay closed marks nothing in play')

-- Open the overlay before constructing avatars.
G.GAME.used_jokers = {}
G.OVERLAY_MENU = nil
lobby = new_lobby()
MPAPI.get_current_lobby = function() return lobby end
dofile('ui/lobby_info_overlay.lua')
MPAPI.show_lobby_info_overlay()
check(G.OVERLAY_MENU ~= nil, 'Lobby Info is open')
check(not G.GAME.used_jokers.j_jolly, 'opening Lobby Info marks no avatar in play')
local shown = MPAPI._active_card_grids[#MPAPI._active_card_grids]._cards[1]
check(shown and shown.config.center.key == 'j_jolly', 'Lobby Info shows the avatar card')

-- Live avatar updates must leave used_jokers unchanged too.
lobby:fire('PLAYER_INFO', 'p1', { preferredJoker = 'j_zany' })
check(shown.config.center.key == 'j_zany', 'the open card is re-skinned')
check(not G.GAME.used_jokers.j_zany, 'an avatar change while Lobby Info is open marks nothing in play')

print(('ok   %d checks'):format(checks))
