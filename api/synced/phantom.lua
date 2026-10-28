-- Phantom copies: a display-only mirror of a joker/consumable shown on opponents' showcase.
-- The consumer configures the showcase area once; `phantom = true` on an
-- MPAPI.Joker/Consumable then auto-broadcasts add/remove and the framework spawns/despawns the
-- copy. A copy is marked by `card.ability.mp_phantom`. Ported from PvP's action_send_phantom / action_remove_phantom + the masking patches.

MPAPI._internal.phantom = MPAPI._internal.phantom or {}

-- cfg = { area = function() -> CardArea }
function MPAPI.configure_phantom(cfg)
	MPAPI._internal.phantom.area = cfg.area
	MPAPI._internal.install_phantom_patches()
end

local function phantom_area()
	local a = MPAPI._internal.phantom.area
	return a and a()
end

local function find_phantom(area, key)
	if not (area and area.cards) then return nil end
	for i = 1, #area.cards do
		local c = area.cards[i]
		if c.ability and c.ability.name == key and c.ability.mp_phantom then
			return c
		end
	end
	return nil
end

-- Apply an incoming phantom add/remove (runs on the opponent's client via the bus demux).
function MPAPI._internal.phantom_apply(obj, data)
	local area = phantom_area()
	if not area then return end
	local key = obj.key
	if data and data.op == 'add' then
		local menu = G.OVERLAY_MENU
		G.OVERLAY_MENU = G.OVERLAY_MENU or true -- spoof a menu: disables duplicate protection
		-- Vanilla create_card ignores a forced key that is banned and rolls a random joker. A ruleset
		-- can ban a joker that the opponent still holds, so lift the ban for this one copy.
		local was_banned = G.GAME.banned_keys[key]
		G.GAME.banned_keys[key] = nil
		local new_card = create_card('Joker', area, false, nil, nil, nil, key)
		G.GAME.banned_keys[key] = was_banned
		new_card.ability.mp_phantom = true
		new_card.ability.eternal = true
		new_card:set_cost()
		new_card:add_to_deck()
		area:emplace(new_card)
		G.OVERLAY_MENU = menu
	elseif data and data.op == 'remove' then
		local card = find_phantom(area, key)
		if card then
			card:remove_from_deck()
			card:start_dissolve({ G.C.RED }, nil, 1.6)
			area:remove_card(card)
		end
	end
end

-- Wrap a synced object's add/remove_from_deck to also broadcast the phantom op. The mirrored
-- copy (marked mp_phantom) must not re-emit. It also labels every phantom copy's tooltip.
function MPAPI._internal.wire_phantom(obj)
	local orig_add = obj.add_to_deck
	local orig_remove = obj.remove_from_deck
	local orig_badges = obj.set_badges
	obj.set_badges = function(self, card, badges)
		if orig_badges then orig_badges(self, card, badges) end
		if card.ability and card.ability.mp_phantom then
			badges[#badges + 1] = create_badge(localize('k_phantom_label'), G.C.PURPLE, G.C.WHITE, 1.0)
		end
	end
	obj.add_to_deck = function(self, card, from_debuffed)
		if orig_add then orig_add(self, card, from_debuffed) end
		if not from_debuffed and not card.ability.mp_phantom then
			MPAPI._internal.sync_broadcast(self, 'phantom', { op = 'add' })
		end
	end
	obj.remove_from_deck = function(self, card, from_debuff)
		if orig_remove then orig_remove(self, card, from_debuff) end
		if not from_debuff and not card.ability.mp_phantom then
			MPAPI._internal.sync_broadcast(self, 'phantom', { op = 'remove' })
		end
	end
end

-- Hide phantom cards from find_card / edition polling / removal duplicate-protection.
-- Installed once when configure_phantom runs (so non-phantom consumers are unaffected).
function MPAPI._internal.install_phantom_patches()
	if MPAPI._internal.phantom._patched then return end
	MPAPI._internal.phantom._patched = true
	local cardremove = Card.remove
	function Card:remove()
		local menu = G.OVERLAY_MENU
		if self.ability and self.ability.mp_phantom then G.OVERLAY_MENU = G.OVERLAY_MENU or true end
		cardremove(self)
		G.OVERLAY_MENU = menu
	end

	local smodsfindcard = SMODS.find_card
	function SMODS.find_card(key, count_debuffed)
		local ret = smodsfindcard(key, count_debuffed)
		local new_ret = {}
		for _, v in ipairs(ret) do
			if not v.ability.mp_phantom then new_ret[#new_ret + 1] = v end
		end
		return new_ret
	end

	local origedpoll = poll_edition
	function poll_edition(_key, _mod, _no_neg, _guaranteed, _options)
		if G.OVERLAY_MENU then return nil end
		return origedpoll(_key, _mod, _no_neg, _guaranteed, _options)
	end
end
