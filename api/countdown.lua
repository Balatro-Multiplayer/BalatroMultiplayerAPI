-----------------------------
-- Countdown overlay
-----------------------------

-- A synced countdown overlay, used to start an action in lockstep across clients
-- (e.g. every client runs this off the same broadcast so the countdown stays in
-- step). Counts down `opts.duration` seconds, updating a single text label in
-- place, then closes the overlay and calls on_complete().
--
-- The timer is REAL-time so the countdown is not sped up by the in-game speed
-- modifier.
--
-- opts (all optional):
--   duration  seconds to count down from (default 5)
--   label     function(n) -> string for the countdown text (default "Starting in N")
--   contents  list of extra UI node rows rendered below the countdown text (e.g. the
--             selected deck backs)
--
-- Shorthand: MPAPI.show_countdown(on_complete) uses the defaults.
MPAPI.show_countdown = function(opts, on_complete)
	if type(opts) == 'function' then
		opts, on_complete = nil, opts
	end
	opts = opts or {}
	local count = opts.duration or 5
	local label = opts.label or function(n)
		return 'Starting in ' .. n
	end

	local contents = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.3 }, nodes = {
			{ n = G.UIT.T, config = { id = 'mpapi_countdown_text', text = label(count), scale = 0.9, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
		} },
	}
	for _, row in ipairs(opts.contents or {}) do
		contents[#contents + 1] = row
	end

	G.FUNCS.overlay_menu({
		definition = create_UIBox_generic_options({
			no_back = true,
			no_esc = true,
			contents = contents,
		}),
		config = { no_esc = true },
	})

	local function tick()
		G.E_MANAGER:add_event(Event({
			trigger = 'after',
			delay = 1,
			-- Real-time so the countdown is not sped up by the game-speed modifier.
			timer = 'REAL',
			blocking = false,
			blockable = false,
			func = function()
				count = count - 1
				if count > 0 then
					local e = G.OVERLAY_MENU and G.OVERLAY_MENU ~= true and G.OVERLAY_MENU:get_UIE_by_ID('mpapi_countdown_text')
					if e then
						e.config.text = label(count)
						if e.UIBox then
							e.UIBox:recalculate()
						end
					end
					tick()
				else
					if G.OVERLAY_MENU and G.OVERLAY_MENU ~= true then
						G.FUNCS.exit_overlay_menu()
					end
					if on_complete then
						on_complete()
					end
				end
				return true
			end,
		}))
	end
	tick()
end
