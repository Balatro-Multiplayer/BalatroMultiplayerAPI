-- Checkpoint index: { {run_idx, ante, blind, event_index}, ... } for a playback session's
-- timeline. event_index is the Driver._cursor value to hand to Driver:fast_forward_to to land
-- at the start of that blind. No recorded opcode carries an ante or blind number, so the only
-- way to learn where "ante N's Big Blind starts" is to dispatch the timeline through a
-- disposable driver and read G.GAME.round_resets.ante / G.GAME.blind_on_deck after each
-- boundary opcode. One flat blind-level index: select_blind and skip_blind fire once per blind,
-- and blind_on_deck resets to 'Small' exactly when the ante advances, so an ante's boundary is
-- just its first row (see MPAPI.playback.checkpoint_ante_boundaries).
--
-- Mod-agnostic. A mod passes its handler namespace and, if it has runs, a run counter.
MPAPI.playback = MPAPI.playback or {}

local DEFAULT_BOUNDARY_OPCODES = { MPAPI.OPCODE.SELECT_BLIND, MPAPI.OPCODE.SKIP_BLIND }

local function to_set(list)
	local set = {}
	for _, opcode in ipairs(list) do
		set[opcode] = true
	end
	return set
end

-- session: { timeline, my_id, bootstrap = { schema_version } }; the driver does not touch it.
-- opts:
--   mod_id            -- handler namespace to dispatch through (required)
--   boundary_opcodes  -- opcodes after which the ante/blind may have changed
--                        (default select_blind, skip_blind; SPDRN adds run_died, run_restarted)
--   run_index()       -- current run number (default: always 1)
--   pause_gate()      -- passed to Driver:fast_forward_to
-- on_built(index) fires once, with the finished index.
--
-- A boundary opcode's handler may apply its effect asynchronously (it pauses the driver and
-- resumes once the transition landed), so G.GAME is read one dispatched entry late: the next
-- entry can only dispatch after the transition settled. The last entry is flushed in on_done.
function MPAPI.playback.build_checkpoint_index(session, opts, on_built)
	local boundary = to_set(opts.boundary_opcodes or DEFAULT_BOUNDARY_OPCODES)
	local run_index = opts.run_index or function()
		return 1
	end
	local index = {}
	local last_key = nil

	local function record_if_new(cursor)
		if not G.GAME then
			return
		end
		local run_idx = run_index()
		local ante = (G.GAME.round_resets and G.GAME.round_resets.ante) or 1
		local blind = G.GAME.blind_on_deck or 'Small'
		local key = run_idx .. ':' .. ante .. ':' .. blind
		if key == last_key then
			return
		end
		last_key = key
		index[#index + 1] = { run_idx = run_idx, ante = ante, blind = blind, event_index = cursor }
	end

	local pending_cursor = nil
	local function on_dispatched(opcode, cursor)
		if pending_cursor then
			record_if_new(pending_cursor)
			pending_cursor = nil
		end
		if boundary[opcode] then
			pending_cursor = cursor
		end
	end

	local driver = MPAPI.playback.new_driver(session.timeline, {
		mod_id = opts.mod_id,
		pov_player_id = session.my_id,
		schema_version = session.bootstrap and session.bootstrap.schema_version,
		on_after_dispatch = function(entry, ctx)
			-- The cursor is already past the dispatched entry: the value fast_forward_to expects.
			on_dispatched(entry.opcode, ctx.driver._cursor)
		end,
	})

	-- Ante 1's first blind starts before any boundary opcode: seed it so a seek to "ante 1"
	-- always finds a row.
	last_key = nil
	record_if_new(1)

	driver:finish()
	driver:fast_forward_to(#session.timeline + 1, {
		pause_gate = opts.pause_gate,
		on_stalled = function(cursor, target)
			MPAPI.sendWarnMessage(
				'[checkpoint_index] build stalled at ' .. tostring(cursor) .. '/' .. tostring(target)
					.. ' -- degrading to normal-pace dispatch to finish it'
			)
		end,
		on_done = function()
			if pending_cursor then
				record_if_new(pending_cursor)
				pending_cursor = nil
			end
			on_built(index)
		end,
	})
end

-- Collapses the blind-level index to one row per (run_idx, ante): the first blind of each ante.
-- A later 'Small' row for an ante already seen means a restart began a fresh attempt at that
-- ante (blind_on_deck resets to 'Small'), so that row replaces the abandoned attempt's.
function MPAPI.playback.checkpoint_ante_boundaries(index)
	local out, last = {}, nil
	for _, e in ipairs(index or {}) do
		local key = e.run_idx .. ':' .. e.ante
		if key ~= last then
			last = key
			out[#out + 1] = e
		elseif e.blind == 'Small' then
			out[#out] = e
		end
	end
	return out
end

-- Sum of the money_delta events from entries[i].event_index up to the next entry's (or the end
-- of the timeline). Memoised on the entry. For an ante-level label pass
-- checkpoint_ante_boundaries(index) as `entries`. money_delta's args is a bare number.
function MPAPI.playback.checkpoint_money_spent(session, entries, i)
	local entry = entries and entries[i]
	if not entry then
		return 0
	end
	if entry._money_spent ~= nil then
		return entry._money_spent
	end
	local from = entry.event_index
	local to = (entries[i + 1] and entries[i + 1].event_index or (#session.timeline + 1)) - 1
	local total = 0
	for j = from, to do
		local ev = session.timeline[j]
		if ev and ev.opcode == MPAPI.OPCODE.MONEY_DELTA and type(ev.args) == 'number' then
			total = total + ev.args
		end
	end
	entry._money_spent = total
	return total
end
