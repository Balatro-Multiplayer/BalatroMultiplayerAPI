-- Match-framing MPAPI.RLOG_CODEs: match_manifest / lobby_info / run_info --
-- replaces the old single "manifest" event (recorder.lua's former
-- RLOG.begin_run(manifest) parameter) with three events at three different
-- scopes, fired at three different times:
--
--   match_manifest -- once per MATCH. start time, which mod, lobby code/type.
--                      Every field is derivable from the environment at
--                      write() time, so write() takes no arguments.
--   lobby_info     -- once per MATCH. gamemode, ruleset, players, deck(s),
--                      lobby options -- content only the calling mod knows,
--                      so write() takes it as arguments.
--   run_info       -- once per individual Balatro RUN (first start AND every
--                      restart within a multi-run match). seed/deck/stake --
--                      only known once a gamemode's own start_run has run.
--
-- All three use dict-shaped args (not positional arrays): they're
-- low-frequency metadata, not high-frequency actions where positional
-- encoding saves real bytes, and named fields are far more readable for
-- something a human/web viewer reads directly (see the web viewer's
-- lib/manifest.ts).
--
-- replay() for all three is a no-op: a driver's bootstrap data (ruleset/
-- gamemode/seed/deck/stake, and now schema_version itself) is read directly
-- off the timeline before playback starts (see each mod's replay_browser.lua
-- find_bootstrap, and driver.lua's opts.schema_version) rather than through
-- ordinary dispatch -- these events exist to be recorded/hashed/displayed,
-- not "applied".
local RLOG = MPAPI.replay

MPAPI.RLOG_CODE {
	key = 'match_manifest',
	mods = { 'pvp', 'spdrn' },
	write = function(self)
		local lobby = MPAPI.get_current_lobby()
		self:record {
			schema_version = RLOG.SCHEMA_VERSION,
			start_epoch_ms = os.time() * 1000,
			mod_id = lobby and lobby.mod_id,
			lobby_code = lobby and lobby.code,
			lobby_type = lobby and lobby.type,
		}
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			-- no-op; see file header
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'lobby_info',
	mods = { 'pvp', 'spdrn' },
	-- players: [{id, is_host}], decks: list of deck keys, options: mod-shaped
	-- table of lobby options (timer settings, ruleset toggles, etc).
	write = function(self, gamemode, ruleset, players, decks, options)
		self:record {
			gamemode = gamemode,
			ruleset = ruleset,
			players = players,
			decks = decks,
			options = options,
		}
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			-- no-op; see file header
		end
	end,
}

MPAPI.RLOG_CODE {
	key = 'run_info',
	mods = { 'pvp', 'spdrn' },
	write = function(self, seed, deck, stake)
		self:record { seed = seed, deck = deck, stake = stake }
	end,
	replay = function(self, _args, ctx)
		if ctx.schema_version >= 1 then
			-- no-op; see file header
		end
	end,
}
