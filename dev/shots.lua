-- Visual scenarios for the draft UI, discovered and run by the
-- BalatroMultiplayerDevTools shot harness. This file is INERT on its own:
-- the API mod never loads it, nothing here executes at boot, and it only
-- runs when a developer with the DevTools mod installed explicitly starts a
-- shot run (BMP_SHOT_SUITE=1 / DEVTOOLS.run_shot_suite()). It lives here --
-- next to dev/test_*.lua -- so the visual scenarios version WITH the code
-- they cover instead of drifting in the tools repo.
--
-- Contract: return function(H) -> list of scenario tables
--   { name, expect, region?, skip?, setup(done), teardown? }
-- H is the harness: H.start_draft(pool, schedule, first), H.find_tile(id),
-- H.find_ui(node, pred). See the DevTools README for the full shape.

return function(H)
	local PLAIN_POOL = { 'b_red', 'b_blue', 'b_yellow', 'b_green', 'b_black', 'b_magic', 'b_nebula', 'b_ghost', 'b_abandoned' }
	local TUPLE_POOL = {
		{ key = 'b_red', stake = 1 }, { key = 'b_red', stake = 5 }, { key = 'b_blue', stake = 3 },
		{ key = 'b_green', stake = 4 }, { key = 'b_black', stake = 1 }, { key = 'b_magic', stake = 3 },
		{ key = 'b_nebula', stake = 5 }, { key = 'b_ghost', stake = 1 }, { key = 'b_abandoned', stake = 4 },
	}
	-- actor = 1 matters: resolve_actor maps a step's actor through state.first,
	-- and a nil actor resolves as actor 2 -- without it every scene renders as
	-- the OPPONENT's turn.
	local BAN3 = { { actor = 1, action = 'ban', count = 3 } }

	-- The centered draft panel (no popups above it).
	local PANEL_REGION = { x = 0.22, y = 0.38, w = 0.56, h = 0.60 }
	-- Panel plus the airspace hover popups grow into.
	local HOVER_REGION = { x = 0.16, y = 0.04, w = 0.68, h = 0.94 }

	local function cocktail_missing()
		return not (G.P_CENTERS and G.P_CENTERS.b_mp_cocktail)
	end

	local function cocktail_pool()
		local pool = { unpack(TUPLE_POOL) }
		pool[3] = {
			key = 'b_mp_cocktail', stake = 3,
			decks = { 'b_green', 'b_black', 'b_mp_orange' },
			name = 'Casjb Cocktail', -- consumer owns the wording; engine renders verbatim
			subtitle = 'A rotating 3-deck mix',
		}
		return pool
	end

	return {
		{
			name = '01-ban-turn-plain',
			expect = "Draft overlay over the main menu: DECK BAN title, 'Your turn' status in green, 9 deck tiles in a row, 'Selected: 0/3' counter, greyed Confirm Ban, blue Random. No ERROR text anywhere.",
			region = PANEL_REGION,
			setup = function(done)
				H.start_draft(PLAIN_POOL, BAN3, 1)
				done()
			end,
		},
		{
			name = '02-selected-2of3',
			expect = "Two tiles (1st and 5th) raised with red 'Selected' tags; counter reads 'Selected: 2/3'; Confirm still greyed (needs exactly 3).",
			region = PANEL_REGION,
			setup = function(done)
				H.start_draft(PLAIN_POOL, BAN3, 1)
				local t1, t2 = H.find_tile('b_red'), H.find_tile('b_black')
				if t1 then t1:click() end
				if t2 then t2:click() end
				done()
			end,
		},
		{
			name = '03-random-armed',
			expect = "No tiles raised; counter reads '?/3'; Random button is RED reading 'Cancel Random'; Confirm is GREEN reading 'Confirm Random'.",
			region = PANEL_REGION,
			setup = function(done)
				H.start_draft(PLAIN_POOL, BAN3, 1)
				G.FUNCS.mpapi_ban_pick_random()
				done()
			end,
		},
		{
			name = '04-offturn-greyed',
			expect = "Status reads waiting/their-turn (not green); counter and BOTH buttons visible but greyed out; layout otherwise identical to scenario 01.",
			region = PANEL_REGION,
			setup = function(done)
				H.start_draft(PLAIN_POOL, BAN3, 2)
				done()
			end,
		},
		{
			name = '05-banned-tiles',
			expect = "Same board as 01 but the 2nd and 8th tiles are debuffed (darkened X overlay); they must not react to anything.",
			region = PANEL_REGION,
			setup = function(done)
				local lobby = H.start_draft(PLAIN_POOL, BAN3, 1)
				lobby._ban_pick.banned['b_blue'] = true
				lobby._ban_pick.banned['b_ghost'] = true
				MPAPI.BanPick.on_state(lobby, lobby._ban_pick)
				done()
			end,
		},
		{
			name = '05b-pick-phase',
			expect = "PICK step between the last 2: seven tiles debuffed, two live; green 'Your turn: pick your deck'; the clicked survivor raised with a GREEN Selected tag; counter 'Selected: 1/1'; GREEN Confirm Pick button.",
			region = PANEL_REGION,
			setup = function(done)
				-- Ranked-shaped 1-3-3 alternating bans, then the pick. Both
				-- sides' bans applied through the host-authoritative
				-- apply_ban (the exact path real remote bans take).
				local lobby = H.start_draft(PLAIN_POOL, {
					{ actor = 2, action = 'ban', count = 1 },
					{ actor = 1, action = 'ban', count = 3 },
					{ actor = 2, action = 'ban', count = 3 },
					{ actor = 1, action = 'pick', count = 1 },
				}, 1)
				local order = lobby._ban_pick.order
				MPAPI.BanPick.apply_ban(lobby, order[2], 'b_blue')
				for _, k in ipairs({ 'b_yellow', 'b_green', 'b_black' }) do
					MPAPI.BanPick.apply_ban(lobby, order[1], k)
				end
				for _, k in ipairs({ 'b_magic', 'b_nebula', 'b_ghost' }) do
					MPAPI.BanPick.apply_ban(lobby, order[2], k)
				end
				MPAPI.BanPick.on_state(lobby, lobby._ban_pick)
				local t = H.find_tile('b_red')
				if t then t:click() end
				done()
			end,
		},
		{
			name = '06-tuple-hover-stake-column',
			expect = "Hover popup over the 7th tile: deck name + effects on the left, stake column on the right (stake name in its colour, description, 'Also applied' list). Popup fully on screen.",
			region = HOVER_REGION,
			setup = function(done)
				H.start_draft(TUPLE_POOL, BAN3, 1)
				local tile = H.find_tile('b_nebula@5')
				if tile then tile:hover() end
				done()
			end,
			teardown = function()
				local tile = H.find_tile('b_nebula@5')
				if tile then tile:stop_hover() end
			end,
		},
		{
			name = '07-cocktail-badge-hover',
			expect = "Badge pill above the tiles reads 'Casjb Cocktail: Green Deck + Black Deck + Orange Deck'; its hover shows the three decks SIDE BY SIDE with full effects, growing downward, fully on screen.",
			region = HOVER_REGION,
			skip = cocktail_missing,
			setup = function(done)
				H.start_draft(cocktail_pool(), BAN3, 1)
				local badge = H.find_ui(G.OVERLAY_MENU, function(n)
					return n.config.mp_comp_item ~= nil
				end)
				if badge then
					-- The rich hover is installed by the badge's per-frame init
					-- func; run it explicitly (idempotent) before hovering.
					G.FUNCS.mpapi_composition_badge_init(badge)
					badge:hover()
				end
				done()
			end,
		},
		{
			name = '08-cocktail-tile-hover-compact',
			expect = "Cocktail tile hover is COMPACT: 'Casjb Cocktail' title, 'rotating 3-deck mix' line, three deck NAMES only (no effect boxes), plus the stake column. Same footprint as a normal deck's hover.",
			region = HOVER_REGION,
			skip = cocktail_missing,
			setup = function(done)
				H.start_draft(cocktail_pool(), BAN3, 1)
				local tile = H.find_tile('b_mp_cocktail@3')
				if tile then tile:hover() end
				done()
			end,
		},
		{
			name = '09-queue-guard-overlay',
			expect = "Guard overlay: 'Matchmaking In Progress' title, description saying you can't start a run or join a lobby while searching, and three buttons -- 'Leave Queue & Continue', 'Leave Queue', 'Stay Queued'. No ERROR text.",
			region = { x = 0.25, y = 0.2, w = 0.5, h = 0.6 },
			-- Only exists once the queue-guard feature is present (PR #7 line).
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				H._guard_revert = H.fake_queue()
				G.SETTINGS.paused = true
				MPAPI.queue_guard_overlay:as_overlay()
				done()
			end,
			teardown = function()
				G.SETTINGS.paused = false
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		-- ── Queue-guard matrix: the guard fired from each REAL entry point, and
		-- what each overlay button leads to. All fake the queued state via
		-- H.fake_queue (no server needed); every trigger goes through the real
		-- wrapped G.FUNCS path a player's click takes.
		{
			name = '10a-newrun-setup-while-queued',
			expect = "The New Run setup screen open while a search runs: 'Queueing m:ss' visible in the connection status panel (left). This is the moment BEFORE clicking Play -- no guard yet.",
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				H._guard_revert = H.fake_queue()
				G.FUNCS.setup_run({ config = {} })
				done()
			end,
			teardown = function()
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		{
			name = '10b-guard-replaces-setup',
			expect = "After clicking Play from that setup screen: the guard REPLACES the setup overlay (as_overlay swaps, it does not stack) -- the run did NOT start, 'Queueing m:ss' still ticking in the status panel.",
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				H._guard_revert = H.fake_queue()
				G.FUNCS.setup_run({ config = {} })
				G.FUNCS.start_run(nil, nil)
				done()
			end,
			teardown = function()
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		{
			name = '11-guard-from-challenges-menu',
			expect = "Guard overlay replacing the challenge list the same way -- starting a challenge while queued is blocked identically to a normal run.",
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				G.FUNCS.challenge_list({ config = {} })
				local revert = H.fake_queue()
				G.FUNCS.start_run(nil, nil)
				H._guard_revert = revert
				done()
			end,
			teardown = function()
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		{
			name = '12-guard-then-stay-queued',
			expect = "After pressing Stay Queued: overlay gone, back at the main menu, and 'Queueing m:ss' STILL ticking in the connection status -- the search survived.",
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				local revert = H.fake_queue()
				G.SETTINGS.paused = true
				MPAPI.queue_guard_overlay:as_overlay()
				G.FUNCS.exit_overlay_menu()
				H._still_queued = MPAPI.matchmaking.is_queued()
				H._guard_revert = revert
				done()
			end,
			teardown = function()
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		{
			name = '13-guard-then-leave-queue',
			expect = "After pressing Leave Queue: overlay gone, menu unpaused, and the 'Queueing' status GONE from the connection panel -- the search ended. No run started.",
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				local revert = H.fake_queue()
				G.SETTINGS.paused = true
				MPAPI.queue_guard_overlay:as_overlay()
				G.FUNCS.mpapi_queue_guard_leave(nil)
				H._guard_revert = revert
				done()
			end,
			teardown = function()
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
		-- LAST on purpose (names sort the run order): Leave Queue & Continue
		-- actually starts the blocked run, which tears down the menu the other
		-- scenarios need. The suite quits right after this capture.
		{
			name = '14-guard-then-leave-and-continue',
			expect = "After pressing Leave Queue & Continue from the New Run guard: the queue is left AND the run actually starts -- captured at the blind-select screen of a fresh RED DECK run (deck forced for determinism; an interaction-on-start deck like Orange would land mid pack-picker instead).",
			settle = 6.0,
			skip = function()
				return not MPAPI.queue_guard_overlay
			end,
			setup = function(done)
				-- Force a passive deck: the run starts on the profile's
				-- remembered deck, and e.g. Orange opens a mandatory pack
				-- picker at run start -- the capture would land mid-pack
				-- instead of at blind select. Restored in teardown.
				local mem = G.PROFILES[G.SETTINGS.profile].MEMORY
				H._mem_deck, H._mem_stake = mem.deck, mem.stake
				mem.deck, mem.stake = 'Red Deck', 1
				G.FUNCS.setup_run({ config = {} })
				-- MEMORY only feeds the New Run tab; with a saved run present the
				-- setup opens on Continue, which sets viewed_back from the SAVE.
				-- Game:start_run gives viewed_back top precedence for a fresh
				-- run (game.lua:2037), so force it directly.
				G.GAME.viewed_back = Back(get_deck_from_name('Red Deck'))
				G.viewed_stake = 1
				local revert = H.fake_queue()
				G.FUNCS.start_run(nil, nil)
				G.FUNCS.mpapi_queue_guard_leave_play(nil)
				H._guard_revert = revert
				done()
			end,
			teardown = function()
				-- The run this scenario starts SAVES over the profile's current
				-- run; delete that suite-created save so it cannot leak into
				-- later runs (a leftover save flips the setup screen to the
				-- Continue tab and changes which deck a scripted start uses).
				pcall(function()
					love.filesystem.remove(G.SETTINGS.profile .. '/save.jkr')
				end)
				local mem = G.PROFILES[G.SETTINGS.profile].MEMORY
				mem.deck, mem.stake = H._mem_deck, H._mem_stake
				H._mem_deck, H._mem_stake = nil, nil
				if H._guard_revert then
					H._guard_revert()
					H._guard_revert = nil
				end
			end,
		},
	}
end
