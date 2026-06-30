-- Closed set of content categories a ruleset/gamemode can ban. Each value is the
-- suffix of the corresponding `banned_<category>` list field on a ruleset or
-- gamemode (e.g. MPAPI.BanCategory.JOKERS -> `banned_jokers`). ApplyBans iterates
-- these to collect keys into G.GAME.banned_keys.
MPAPI.BanCategory = {
	JOKERS = 'jokers',
	CONSUMABLES = 'consumables',
	VOUCHERS = 'vouchers',
	ENHANCEMENTS = 'enhancements',
	TAGS = 'tags',
	BLINDS = 'blinds',
}
