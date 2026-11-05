-- The pop up for Notifications that waited while the player was offline
-- (api/notification/inbox.lua queues them at login). One at a time, with
-- "1 of N" and OK. The next shows only when nothing else is open, so no
-- overlay covers or replaces another. OK is the only way out.
local inbox = MPAPI._internal.notification_inbox
local Queue = MPAPI.load_mpapi_file('api/notification/queue.lua')

local LINE_WIDTH = 64
local MAX_LINES = 9

local _state = { text = '', position = 1, total = 1 }

-----------------------------
-- PURE
-----------------------------

-- Splits text into lines of at most `width` characters at spaces (a longer
-- word is cut), keeping at most `max_lines` (the last ends in '...').
local function wrap(text, width, max_lines)
	local lines, line = {}, ''
	local function push(l)
		lines[#lines + 1] = l
	end
	for word in text:gmatch('%S+') do
		while #word > width do
			if line ~= '' then
				push(line)
				line = ''
			end
			push(word:sub(1, width))
			word = word:sub(width + 1)
		end
		if line == '' then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. ' ' .. word
		else
			push(line)
			line = word
		end
	end
	if line ~= '' then
		push(line)
	end
	if max_lines and #lines > max_lines then
		local kept = {}
		for i = 1, max_lines do
			kept[i] = lines[i]
		end
		kept[max_lines] = kept[max_lines]:sub(1, width - 3) .. '...'
		return kept
	end
	return lines
end

-----------------------------
-- UI FUNCTIONS
-----------------------------

local function text_row(text, scale, colour)
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.02 },
		nodes = { { n = G.UIT.T, config = { text = text, scale = scale, colour = colour or G.C.UI.TEXT_LIGHT } } },
	}
end

local create_UIBox_notification_overlay = function()
	local nodes = {
		text_row(localize('k_notification_title'), 0.55),
		text_row(string.format(localize('k_notification_position'), _state.position, _state.total), 0.3, G.C.UI.TEXT_INACTIVE),
	}
	local rows = {}
	for _, line in ipairs(wrap(_state.text, LINE_WIDTH, MAX_LINES)) do
		rows[#rows + 1] = text_row(line, 0.34)
	end
	nodes[#nodes + 1] = {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.12, r = 0.1, colour = G.C.BLACK, minw = 7.5 },
		nodes = { { n = G.UIT.C, config = { align = 'cm' }, nodes = rows } },
	}
	nodes[#nodes + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
	nodes[#nodes + 1] = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{ n = G.UIT.C, config = {
				align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
				colour = G.C.ORANGE, shadow = true, hover = true, button = 'mpapi_notification_dismiss',
			}, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_ok'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
		},
	}
	local contents = {
		{ n = G.UIT.C, config = { align = 'cm', minw = 8, padding = 0.2, r = 0.1, colour = G.C.CLEAR }, nodes = nodes },
	}
	return create_UIBox_generic_options({ snap_back = true, no_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

-- Outside a run, on the main menu, with no other overlay up.
local function can_show_now()
	return G.STAGE == G.STAGES.MAIN_MENU and not G.OVERLAY_MENU and G.MAIN_MENU_UI ~= nil
end

local function show_next()
	local entry, position, total = Queue.next(inbox.queue)
	if not entry then
		return
	end
	_state.text, _state.position, _state.total = entry.text, position, total
	-- Read once shown, so a crash before OK does not show it again.
	if entry.on_shown then
		entry.on_shown()
	end
	MPAPI.notification_overlay:as_overlay()
end

G.FUNCS.mpapi_notification_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- TRIGGERS
-----------------------------

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function(...)
	if can_show_now() then
		-- The last overlay is gone; the next one may open.
		Queue.close(inbox.queue)
		if Queue.ready(inbox.queue, inbox.now()) then
			show_next()
		end
	end
	return MPAPI_update_ref(...)
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.notification_overlay = MPAPI.ui_element(create_UIBox_notification_overlay)

-- For tests.
MPAPI._internal.notification_overlay = { wrap = wrap, can_show_now = can_show_now, show_next = show_next }
