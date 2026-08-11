-- Per-mod extension point for the lobby-card hover popup and Lobby Info
-- overlay: each mod registers one callback (mod-wide, not per-gamemode --
-- "SPDRN shows enemy location"/"ranked shows Elo" both cut across a mod's
-- whole gamemode set) that returns extra hover rows for a given player.
MPAPI._card_info_providers = {}

function MPAPI.register_card_info_provider(mod_id, fn)
	MPAPI._card_info_providers[mod_id] = fn
end

-- Collects extra hover rows for `player_data` from the provider registered
-- for THIS lobby's owning mod only (lobby.mod_id) -- e.g. a player with both
-- SPDRN and PvP installed must not see PvP's Elo row while hovering a card
-- in an SPDRN lobby just because PvP also registered a provider. A provider
-- that errors is skipped (via pcall) so a buggy callback can't break the
-- whole hover popup.
function MPAPI._build_card_info_rows(lobby, player_data)
	local rows = {}
	local fn = lobby and lobby.mod_id and MPAPI._card_info_providers[lobby.mod_id]
	if not fn then
		return rows
	end
	local ok, extra = pcall(fn, lobby, player_data)
	if ok and extra then
		for _, row in ipairs(extra) do
			rows[#rows + 1] = row
		end
	end
	return rows
end
