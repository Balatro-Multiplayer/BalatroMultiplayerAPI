-- Swaps the BALATRO title logo for the focused mod's custom title while its menu is shown.
-- A mod opts in via register_mod{ title = { base = <atlas_key>, extra = <atlas_key>? } }. The
-- base atlas becomes G.SPLASH_LOGO (drawn last, so on top); the optional extra atlas is a second
-- sprite drawn in the moveable loop, which runs before SPLASH_LOGO (so it sits behind the base).
-- The title_top cards are hidden while a custom title is shown so they don't poke through it.

local function atlas(key)
	return key and (G.ASSET_ATLAS[key] or (SMODS.Atlases and SMODS.Atlases[key])) or nil
end

-- A title-logo sprite for an atlas, sized and aligned like the vanilla SPLASH_LOGO.
local function title_sprite(a)
	local sc = 1.1 * (G.debug_splash_size_toggle and 0.8 or 1)
	local s = Sprite(0, 0, 13 * sc, 13 * sc * (a.py / a.px), a, { x = 0, y = 0 })
	s:set_alignment({ major = G.title_top, type = 'cm', bond = 'Strong', offset = { x = 0, y = 0 } })
	s:define_draw_steps({ { shader = 'dissolve' } })
	s.dissolve_colours = { G.C.WHITE, G.C.WHITE }
	-- dissolve is fully-formed at 0; the vanilla logo only sits at 1 mid intro animation.
	s.dissolve = 0
	return s
end

local _extra = nil
local _hidden_cards = {}

local function remove_extra()
	if not _extra then return end
	local s = _extra
	_extra = nil
	pcall(function() s:remove() end)
end

local function set_logo(a, tag)
	if G.SPLASH_LOGO then pcall(function() G.SPLASH_LOGO:remove() end) end
	G.SPLASH_LOGO = title_sprite(a)
	G.SPLASH_LOGO._mpapi_title = tag
end

local function apply_title(cfg)
	if not G.title_top then return end
	local base = atlas(cfg.base)
	if not (base and base.image) then return end

	set_logo(base, cfg)

	remove_extra()
	local ex = atlas(cfg.extra)
	if ex and ex.image then
		local s = title_sprite(ex)
		table.insert(G.I.MOVEABLE, s)
		_extra = s
	end
end

local function restore_vanilla()
	remove_extra()
	if G.title_top and G.ASSET_ATLAS['balatro'] then
		set_logo(G.ASSET_ATLAS['balatro'], nil)
	end
end

local function hide_title_cards()
	if not (G.title_top and G.title_top.cards) then return end
	for _, c in ipairs(G.title_top.cards) do
		if c.states and c.states.visible ~= false then
			c.states.visible = false
			_hidden_cards[#_hidden_cards + 1] = c
		end
	end
end

local function show_title_cards()
	for _, c in ipairs(_hidden_cards) do
		if c and c.states then c.states.visible = true end
	end
	_hidden_cards = {}
end

local function manage_title()
	if not G.SPLASH_LOGO then
		remove_extra()
		return
	end
	local cfg = MPAPI._internal.get_active_title and MPAPI._internal.get_active_title()
	if cfg then
		if G.SPLASH_LOGO._mpapi_title ~= cfg then apply_title(cfg) end
		hide_title_cards()
	elseif G.SPLASH_LOGO._mpapi_title then
		restore_vanilla()
		show_title_cards()
	end
end

if not MPAPI._title_update_hooked then
	MPAPI._title_update_hooked = true
	local _ref = Game.update
	function Game:update(dt)
		_ref(self, dt)
		pcall(manage_title)
	end
end
