-- The live pre-match lobby roster. Card-grid building/pagination lives in
-- ui/lobby_card_grid.lua (MPAPI._new_card_grid) so this file and
-- ui/lobby_info_overlay.lua's Players tab can each run their own grid
-- instance against the same lobby.
local lobby_card_click_override
local lobby_card_hover_override

-----------------------------
-- API FUNCTIONS
-----------------------------

MPAPI.create_lobby_ui = function(lobby)
	local grid = MPAPI._new_card_grid()
	return grid:build_element(lobby)
end

-----------------------------
-- OVERRIDES
-----------------------------

local function find_owning_grid(card)
	for _, grid in ipairs(MPAPI._active_card_grids) do
		if grid:contains_card(card) then
			return grid
		end
	end
	return nil
end

lobby_card_click_override = function(self)
	if self.params.mpapi_lobby_card then
		if self.facing == 'front' then
			local grid = find_owning_grid(self)
			if grid then
				local player_data = grid:get_player_for_card(self)
				if player_data and grid.lobby and player_data.id ~= grid.lobby.player_id then
					MPAPI.open_player_mute_overlay(player_data.id, player_data.displayName or 'Unknown')
				end
			end
		end
		return true
	end
end

lobby_card_hover_override = function(self)
	if not self.params.mpapi_lobby_card then
		return false
	end

	if self.facing ~= 'front' then
		return true
	end

	self:juice_up(0.05, 0.03)
	play_sound('paper1', math.random() * 0.2 + 0.9, 0.35)

	local grid = find_owning_grid(self)
	local player_data = grid and grid:get_player_for_card(self)
	if not player_data then
		return true
	end

	local display_name = player_data.displayName or 'Unknown'

	local badges = { create_badge('Player', MPAPI.C.MP_EDITION, G.C.WHITE, 1.2) }

	-- No ready-check concept in public (matchmaking-made) lobbies from the
	-- player's perspective -- never shown there at all. Nor in-game: ready
	-- status only ever means anything pre-match (the Lobby Info overlay's
	-- in-run card grid uses this exact same hover override), so it's
	-- meaningless there regardless of lobby type. In private pre-match
	-- lobbies, default an untouched (nil) ready state to Not Ready rather
	-- than hiding the badge, since every player in a private lobby is a real
	-- ready/not-ready candidate even before they've ever pressed the toggle.
	if G.STAGE ~= G.STAGES.RUN and (not grid.lobby or grid.lobby.type ~= 'public') then
		local ready = player_data.ready
		if ready == nil then
			ready = false
		end
		badges[#badges + 1] = create_badge(
			localize(ready and 'k_ready' or 'k_not_ready'),
			ready and G.C.GREEN or G.C.RED,
			G.C.WHITE, 1.2
		)
	end

	-- First description box: always non-empty, standard for every player
	-- regardless of mod/gamemode -- mod count, plus a Muted line if we have
	-- them muted. Unlike the second box below, this one never has an "empty"
	-- state to handle.
	local mods_rows = {}
	if player_data.mods == nil then
		mods_rows[1] = { { n = G.UIT.T, config = { text = localize('k_lobby_card_mods_loading'), scale = 0.32, colour = G.C.UI.TEXT_DARK } } }
	else
		mods_rows[1] = { { n = G.UIT.T, config = { text = tostring(#player_data.mods) .. ' ' .. localize('k_mods_word'), scale = 0.32, colour = G.C.UI.TEXT_DARK } } }
	end
	if MPAPI.connection_state.mute_list[player_data.id] then
		mods_rows[#mods_rows + 1] = { { n = G.UIT.T, config = { text = localize('k_muted_label'), scale = 0.32, colour = G.C.UI.TEXT_DARK } } }
	end

	-- Second description box ("live game stats"): the owning mod's card-info
	-- provider (rank/Elo, location, etc. -- api/card_info_providers.lua),
	-- shown only when it actually has something to say -- e.g. pre-match, or
	-- for a mod with no per-card info at all (PvP's non-ranked case), there's
	-- nothing to display and this box doesn't render. Each provider row is
	-- already a full {n=G.UIT.R, nodes={text node}} row (the same shape
	-- ui/lobby_info_overlay.lua/player_mute_overlay.lua use as-is);
	-- desc_from_rows wants just the inner `nodes` array per row, so unwrap it.
	local stat_rows = {}
	if grid.lobby then
		for _, row in ipairs(MPAPI._build_card_info_rows(grid.lobby, player_data)) do
			stat_rows[#stat_rows + 1] = row.nodes or {}
		end
	end

	self.ability_UIBox_table = {
		card_type = 'Joker',
		name = {
			{ n = G.UIT.O, config = {
				object = DynaText({
					string = { display_name },
					colours = { G.C.WHITE },
					float = true,
					shadow = true,
					scale = 0.45,
					silent = true,
				}),
			} },
		},
		main = mods_rows,
		badges = {},
		info = {},
	}

	-- Mirrors G.UIDEF.card_h_popup's own chrome exactly (outer border box,
	-- inner card_type-tinted box, name -> description -> badges order), so
	-- this reads as a real card/Joker tooltip -- just with badges we own
	-- (Player/Ready) in the bottom row instead of vanilla's rarity/edition
	-- badge system, which only understands its own fixed set of badge keys.
	local card_type_background = darken(G.C.BLACK, 0.1)
	self.config.h_popup = {
		n = G.UIT.ROOT,
		config = { align = 'cm', colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.C,
				config = { align = 'cm' },
				nodes = {
					{
						n = G.UIT.R,
						config = { padding = 0.05, r = 0.12, colour = lighten(G.C.JOKER_GREY, 0.5), emboss = 0.07 },
						nodes = {
							{
								n = G.UIT.R,
								config = { align = 'cm', padding = 0.07, r = 0.1, colour = adjust_alpha(card_type_background, 0.8) },
								nodes = {
									name_from_rows(self.ability_UIBox_table.name),
									desc_from_rows(self.ability_UIBox_table.main),
									#stat_rows > 0 and desc_from_rows(stat_rows) or nil,
									{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = badges },
								},
							},
						},
					},
				},
			},
		},
	}
	self.config.h_popup_config = self:align_h_popup()
	Node.hover(self)

	return true
end

local _card_click_ref = Card.click
function Card:click()
	if lobby_card_click_override(self) then
		return
	end
	_card_click_ref(self)
end

local _card_hover_ref = Card.hover
function Card:hover()
	if lobby_card_hover_override(self) then
		return
	end
	_card_hover_ref(self)
end
