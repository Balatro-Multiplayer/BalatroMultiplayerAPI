-- "Warning from a moderator" notice for WARNED (109): a moderator answered a
-- service-queue item (a report, flagged chat, ...) with a warning. Like the
-- ban notice it is the server's own wording; like the avatar notice it waits
-- until the player is on the main menu with nothing else open, and every
-- warning that arrived meanwhile is shown together.
--
-- 109 is persistent: a warning issued while offline waits in the notification
-- list and is read at login. Each is deleted once shown, so it is shown once.
local notify = MPAPI.networking.nakama_notify
local C = MPAPI._internal.conn

-- BalatroMultiplayerServer apps/server features/service-queue command.ts:
-- a warning's message is at most 500 characters.
local LINE_WIDTH = 64
local MAX_LINES_PER_WARNING = 9

-----------------------------
-- STATE
-----------------------------

local _state = {
	-- Warnings not shown yet ({message, warned_at}), in arrival order.
	queued = {},
	-- Stored notifications behind the queued warnings, deleted once shown.
	notification_ids = {},
	-- Notifications already taken (live and listed copies of one 109 overlap).
	seen = {},
	-- The warnings on the open notice.
	shown = {},
}

-----------------------------
-- PURE
-----------------------------

-- A 109's content ({message, itemType, warnedAt}) as a warning, or nil when
-- it carries no message to show.
local function warning_of(content)
	if type(content) ~= 'table' or type(content.message) ~= 'string' then
		return nil
	end
	local message = content.message:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
	if message == '' then
		return nil
	end
	return { message = message, warned_at = tonumber(content.warnedAt) }
end

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

-- "2026-10-21 14:05 UTC" from epoch ms, or nil.
local function date_text(warned_at)
	if not warned_at then
		return nil
	end
	return os.date('!%Y-%m-%d %H:%M UTC', math.floor(warned_at / 1000))
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

local function warning_block(warning)
	local rows = {}
	for _, line in ipairs(wrap(warning.message, LINE_WIDTH, MAX_LINES_PER_WARNING)) do
		rows[#rows + 1] = text_row(line, 0.34)
	end
	local date = date_text(warning.warned_at)
	if date then
		rows[#rows + 1] = text_row(date, 0.26, G.C.UI.TEXT_INACTIVE)
	end
	return {
		n = G.UIT.R,
		config = { align = 'cm', padding = 0.12, r = 0.1, colour = G.C.BLACK, minw = 7.5 },
		nodes = { { n = G.UIT.C, config = { align = 'cm' }, nodes = rows } },
	}
end

local create_UIBox_warned_notice_overlay = function()
	local warnings = _state.shown
	local nodes = {
		text_row(localize('k_warned_title'), 0.55),
		text_row(localize(#warnings > 1 and 'k_warned_body_plural' or 'k_warned_body'), 0.32),
	}
	for _, warning in ipairs(warnings) do
		nodes[#nodes + 1] = warning_block(warning)
	end
	nodes[#nodes + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
	nodes[#nodes + 1] = {
		n = G.UIT.R,
		config = { align = 'cm' },
		nodes = {
			{ n = G.UIT.C, config = {
				align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
				colour = G.C.ORANGE, shadow = true, hover = true, button = 'mpapi_warned_notice_dismiss',
			}, nodes = {
				{ n = G.UIT.T, config = { text = localize('k_warned_ack'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
			} },
		},
	}
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.2, r = 0.1, colour = G.C.CLEAR },
			nodes = nodes,
		},
	}

	-- The acknowledge button is the only way out.
	return create_UIBox_generic_options({ snap_back = true, no_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

local function nakama_client()
	return C.connection and C.connection.nakama_client
end

-- Takes one 109 (live or listed). notification_id: the stored copy to delete
-- once shown, nil for one that isn't stored.
local function enqueue(content, notification_id)
	if notification_id then
		if _state.seen[notification_id] then
			return
		end
		_state.seen[notification_id] = true
	end
	local warning = warning_of(content)
	if notification_id then
		-- One without a message is deleted too: there is nothing to show.
		_state.notification_ids[#_state.notification_ids + 1] = notification_id
	end
	if warning then
		_state.queued[#_state.queued + 1] = warning
	end
end

-- Outside a run, on the main menu, with no other overlay up.
local function can_show_now()
	return G.STAGE == G.STAGES.MAIN_MENU and not G.OVERLAY_MENU and G.MAIN_MENU_UI ~= nil
end

local function show_queued()
	_state.shown = _state.queued
	_state.queued = {}
	notify.delete_persistent(nakama_client(), _state.notification_ids)
	_state.notification_ids = {}
	MPAPI.warned_notice_overlay:as_overlay()
end

local function forget_all()
	_state.queued = {}
	_state.notification_ids = {}
	_state.seen = {}
end

G.FUNCS.mpapi_warned_notice_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- TRIGGERS
-----------------------------

if notify then
	notify.on(notify.Code.WARNED, function(content, notification)
		MPAPI.sendWarnMessage('[moderation] warned: ' .. tostring(type(content) == 'table' and content.message))
		enqueue(content, notification and notification.persistent and notification.id or nil)
	end)
end

-- At login: warnings issued while offline.
local function on_state_change(new_state, context)
	local old_state = context and context.old_state
	if new_state == MPAPI.ConnectionState.CONNECTED and old_state ~= nil and old_state ~= new_state then
		notify.list_persistent(nakama_client(), notify.Code.WARNED, function(stored)
			for _, notification in ipairs(stored) do
				enqueue(notification.content_table, notification.id)
			end
		end)
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED then
		-- Still stored server-side: the next login lists them again.
		forget_all()
	end
end
C.state_change_callbacks = C.state_change_callbacks or {}
table.insert(C.state_change_callbacks, on_state_change)

local MPAPI_update_ref = MPAPI.update
MPAPI.update = function(...)
	if #_state.queued > 0 and can_show_now() then
		show_queued()
	end
	return MPAPI_update_ref(...)
end

-----------------------------
-- GLOBAL UI ELEMENT
-----------------------------

MPAPI.warned_notice_overlay = MPAPI.ui_element(create_UIBox_warned_notice_overlay)

-- For tests: the pure helpers, the queue as it stands, and a way to feed it.
MPAPI._internal.warned_notice = {
	warning_of = warning_of,
	wrap = wrap,
	date_text = date_text,
	queued = function()
		return _state.queued
	end,
	pending_deletes = function()
		return _state.notification_ids
	end,
	shown = function()
		return _state.shown
	end,
	enqueue = enqueue,
	can_show_now = can_show_now,
	on_state_change = on_state_change,
	reset = forget_all,
}
