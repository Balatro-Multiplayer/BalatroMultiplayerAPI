-- §17.9: shared pause-menu extras. SPDRN and PvP each replace the base game's
-- pause menu with their own overlay (Settings/Seed Change or Forfeit/etc.),
-- but the design doc's claimed 5-button set (Seed Change, Forfeit, Settings,
-- Collection, Mods) only ever had 3 built for either mod -- Collection and
-- Mods were simply never added. Both are ordinary vanilla/SMODS globals
-- (G.FUNCS.your_collection, G.FUNCS.mods_button) reachable from any overlay
-- regardless of context, so this is one shared helper rather than duplicating
-- the same two UIBox_button rows in both mods.
--
-- Returns a list of pre-built row nodes ({ n = G.UIT.R, ... }), ready to
-- append directly into a consumer's own `rows` table alongside its
-- mode-specific buttons (Seed Change, Forfeit, etc.).
function MPAPI.pause_menu_extra_rows()
	return {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'your_collection', label = { localize('b_collection') }, minw = 5 }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'mods_button', label = { localize('b_mods_cap') }, minw = 5 }),
		} },
	}
end
