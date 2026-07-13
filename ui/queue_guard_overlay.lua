-- Overlay shown when the player tries to do something that conflicts with an
-- active matchmaking search -- start a run (New Run, Continue, Challenge,
-- restart) or create/join a lobby. The gate lives in
-- api/matchmaking/queue_guard.lua (guard_queued), which opens this in place of
-- letting the blocked action proceed.
--
-- Three ways out, all always available (never soft-locks, even if the search
-- ends while this is open -- no dismiss branch reads search state):
--   Leave Queue & Continue -- leaves every active handle, then replays the
--                         blocked action (re-checked by the gate on the way through).
--   Leave Queue        -- leaves every active handle, then dismisses back to
--                         the menu.
--   Stay Queued        -- the overlay's own back button (and Esc); dismisses.
local create_UIBox_queue_guard_overlay = function()
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 6, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_queue_guard_title'), scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_queue_guard_desc'), scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.15 } },
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.05 },
					nodes = {
						{
							n = G.UIT.C,
							config = {
								align = 'cm', padding = 0.1, minw = 4, minh = 0.7,
								r = 0.1, hover = true, colour = G.C.BLUE, shadow = true,
								button = 'mpapi_queue_guard_leave_play',
							},
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_queue_guard_leave_play'), scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
							},
						},
					},
				},
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.05 },
					nodes = {
						{
							n = G.UIT.C,
							config = {
								align = 'cm', padding = 0.1, minw = 4, minh = 0.7,
								r = 0.1, hover = true, colour = G.C.RED, shadow = true,
								button = 'mpapi_queue_guard_leave',
							},
							nodes = {
								{ n = G.UIT.T, config = { text = localize('b_queue_guard_leave'), scale = 0.38, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
							},
						},
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({
		snap_back = true,
		back_colour = G.C.GREEN,
		back_label = localize('b_queue_guard_stay'),
		contents = contents,
	})
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

-- Leave every active matchmaking handle (the same per-handle path a
-- consumer mod's own Cancel-Search button uses: handle:leave() marks it left,
-- removes it from mm.handles, fires its 'left' event, and tells the server).
-- Copy the list first -- handle:leave() mutates mm.handles in place via
-- mm.remove_handle, which would break live iteration.
local function leave_all_handles()
	local mm = MPAPI._internal.mm
	local handles = MPAPI.shallow_copy(mm.handles or {})
	for _, h in ipairs(handles) do
		h:leave()
	end
end

G.FUNCS.mpapi_queue_guard_leave = function(e)
	leave_all_handles()
	G.FUNCS.exit_overlay_menu()
end

-- Leave the queue and immediately replay whatever was blocked (a run-start, a
-- lobby create, or a lobby join -- stashed as a closure by guard_queued). The
-- replay re-enters the same guarded entry point, so the gate is re-checked --
-- if anything is still searching it re-blocks rather than proceeding.
G.FUNCS.mpapi_queue_guard_leave_play = function(e)
	leave_all_handles()
	G.FUNCS.exit_overlay_menu()
	local mm = MPAPI._internal.mm
	local action = mm.pending_action
	mm.pending_action = nil
	if action then
		action()
	end
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.queue_guard_overlay = MPAPI.ui_element(create_UIBox_queue_guard_overlay)
