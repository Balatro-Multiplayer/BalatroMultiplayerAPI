-- Phantom copies: a display-only mirror of a joker/consumable shown on opponents' showcase.
-- The consumer configures the showcase area + phantom edition once; `phantom = true` on an
-- MPAPI.Joker/Consumable then auto-broadcasts add/remove and the framework spawns/despawns the
-- copy. Ported from PvP's action_send_phantom / action_remove_phantom + the masking patches.

MPAPI._internal.phantom = MPAPI._internal.phantom or {}

-- cfg = { area = function() -> CardArea, edition = 'e_<key>' }
function MPAPI.configure_phantom(cfg)
	MPAPI._internal.phantom.area = cfg.area
	MPAPI._internal.phantom.edition = cfg.edition
	MPAPI._internal.phantom.edition_type = cfg.edition and cfg.edition:gsub('^e_', '') or nil
	MPAPI._internal.install_phantom_patches()
end

local function phantom_area()
	local a = MPAPI._internal.phantom.area
	return a and a()
end

local function find_phantom(area, key, etype)
	if not (area and area.cards) then return nil end
	for i = 1, #area.cards do
		local c = area.cards[i]
		if c.ability and c.ability.name == key and c.edition and c.edition.type == etype then
			return c
		end
	end
	return nil
end

-- Apply an incoming phantom add/remove (runs on the opponent's client via the bus demux).
function MPAPI._internal.phantom_apply(obj, data)
	local area = phantom_area()
	local edition = MPAPI._internal.phantom.edition
	local etype = MPAPI._internal.phantom.edition_type
	if not (area and edition) then return end
	local key = obj.key
	if data and data.op == 'add' then
		local menu = G.OVERLAY_MENU
		G.OVERLAY_MENU = G.OVERLAY_MENU or true -- spoof a menu: disables duplicate protection
		local new_card = create_card('Joker', area, false, nil, nil, nil, key)
		new_card:set_edition(edition)
		new_card:add_to_deck()
		area:emplace(new_card)
		G.OVERLAY_MENU = menu
	elseif data and data.op == 'remove' then
		local card = find_phantom(area, key, etype)
		if card then
			card:remove_from_deck()
			card:start_dissolve({ G.C.RED }, nil, 1.6)
			area:remove_card(card)
		end
	end
end

-- Wrap a synced object's add/remove_from_deck to also broadcast the phantom op. The mirrored
-- copy (phantom edition) must not re-emit. edition_type is read at call time so configure_phantom
-- may run before or after the object is defined.
function MPAPI._internal.wire_phantom(obj)
	local orig_add = obj.add_to_deck
	local orig_remove = obj.remove_from_deck
	obj.add_to_deck = function(self, card, from_debuffed)
		if orig_add then orig_add(self, card, from_debuffed) end
		local etype = MPAPI._internal.phantom.edition_type
		if not from_debuffed and (not card.edition or card.edition.type ~= etype) then
			MPAPI._internal.sync_broadcast(self, 'phantom', { op = 'add' })
		end
	end
	obj.remove_from_deck = function(self, card, from_debuff)
		if orig_remove then orig_remove(self, card, from_debuff) end
		local etype = MPAPI._internal.phantom.edition_type
		if not from_debuff and (not card.edition or card.edition.type ~= etype) then
			MPAPI._internal.sync_broadcast(self, 'phantom', { op = 'remove' })
		end
	end
end

-- Hide phantom-edition cards from find_card / edition polling / removal duplicate-protection.
-- Installed once when configure_phantom runs (so non-phantom consumers are unaffected).
function MPAPI._internal.install_phantom_patches()
	if MPAPI._internal.phantom._patched then return end
	MPAPI._internal.phantom._patched = true
	local function etype()
		return MPAPI._internal.phantom.edition_type
	end

	local cardremove = Card.remove
	function Card:remove()
		local menu = G.OVERLAY_MENU
		if self.edition and self.edition.type == etype() then G.OVERLAY_MENU = G.OVERLAY_MENU or true end
		cardremove(self)
		G.OVERLAY_MENU = menu
	end

	local smodsfindcard = SMODS.find_card
	function SMODS.find_card(key, count_debuffed)
		local ret = smodsfindcard(key, count_debuffed)
		local new_ret = {}
		for _, v in ipairs(ret) do
			if not v.edition or v.edition.type ~= etype() then new_ret[#new_ret + 1] = v end
		end
		return new_ret
	end

	local origedpoll = poll_edition
	function poll_edition(_key, _mod, _no_neg, _guaranteed, _options)
		if G.OVERLAY_MENU then return nil end
		return origedpoll(_key, _mod, _no_neg, _guaranteed, _options)
	end
end
