-- "Avatar unlocked" notice for AVATAR_UNLOCKED (107). The unlocks are earned
-- by a game that just ended, so the notice waits until the player is back on
-- the main menu with nothing else open, and everything that arrived meanwhile
-- is shown together. Same small modal shape as ui/banned_notice_overlay.lua.
--
-- 107 is persistent: one earned while offline waits in the notification list
-- and is read at login. Each is deleted once shown, so it is shown once.
local notify = MPAPI.networking.nakama_notify
local C = MPAPI._internal.conn

-----------------------------
-- STATE
-----------------------------

local _state = {
	-- Avatar ids not shown yet, in arrival order, and the set of them.
	queued = {},
	queued_set = {},
	-- Stored notifications behind the queued ids, deleted once shown.
	notification_ids = {},
	-- Notifications already taken (live and listed copies of one 107 overlap).
	seen = {},
	-- The ids on the open notice.
	shown = {},
}

-----------------------------
-- PURE
-----------------------------

local function avatar_name(id)
	local ok, name = pcall(localize, { type = 'name_text', set = 'Joker', key = id })
	if ok and type(name) == 'string' and name ~= '' and name ~= 'ERROR' then
		return name
	end
	return id
end

-- "Baron, Swashbuckler"
local function names_text(ids)
	local names = {}
	for _, id in ipairs(ids) do
		names[#names + 1] = avatar_name(id)
	end
	return table.concat(names, ', ')
end

-----------------------------
-- UI FUNCTIONS
-----------------------------

local function avatar_cards_row(ids)
	local nodes = {}
	for _, id in ipairs(ids) do
		local center = G.P_CENTERS[id]
		if center then
			local card = Card(0, 0, G.CARD_W * 0.7, G.CARD_H * 0.7, nil, center, { bypass_discovery_center = true, bypass_lock = true })
			card.no_ui = true
			card.states.drag.can = false
			nodes[#nodes + 1] = { n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
				{ n = G.UIT.O, config = { object = card } },
			} }
		end
	end
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = nodes }
end

local create_UIBox_avatar_unlocked_toast = function()
	local ids = _state.shown
	local contents = {
		{
			n = G.UIT.C,
			config = { align = 'cm', minw = 8, padding = 0.25, r = 0.1, colour = G.C.CLEAR },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.1 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_avatar_unlocked_title'), scale = 0.55, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
					},
				},
				avatar_cards_row(ids),
				{
					n = G.UIT.R,
					config = { align = 'cm', padding = 0.06 },
					nodes = {
						{ n = G.UIT.T, config = { text = localize('k_avatar_unlocked_body') .. ' ' .. names_text(ids), scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
					},
				},
				{ n = G.UIT.R, config = { minh = 0.2 } },
				{
					n = G.UIT.R,
					config = { align = 'cm' },
					nodes = {
						{ n = G.UIT.C, config = {
							align = 'cm', padding = 0.15, minw = 5, minh = 0.7, r = 0.1,
							colour = G.C.GREEN, shadow = true, hover = true, button = 'mpapi_avatar_unlocked_dismiss',
						}, nodes = {
							{ n = G.UIT.T, config = { text = localize('k_ok'), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
						} },
					},
				},
			},
		},
	}

	return create_UIBox_generic_options({ snap_back = true, contents = contents })
end

-----------------------------
-- LOGIC FUNCTIONS
-----------------------------

local function nakama_client()
	return C.connection and C.connection.nakama_client
end

-- Takes one 107 (live or listed). notification_id: the stored copy to delete
-- once shown, nil for one that isn't stored.
local function enqueue(content, notification_id)
	if notification_id then
		if _state.seen[notification_id] then
			return
		end
		_state.seen[notification_id] = true
		_state.notification_ids[#_state.notification_ids + 1] = notification_id
	end
	for _, id in ipairs((type(content) == 'table' and content.avatarIds) or {}) do
		if type(id) == 'string' and not _state.queued_set[id] then
			_state.queued_set[id] = true
			_state.queued[#_state.queued + 1] = id
		end
	end
end

-- Outside a run, on the main menu, with no other overlay up.
local function can_show_now()
	return G.STAGE == G.STAGES.MAIN_MENU and not G.OVERLAY_MENU and G.MAIN_MENU_UI ~= nil
end

local function show_queued()
	_state.shown = _state.queued
	_state.queued = {}
	_state.queued_set = {}
	notify.delete_persistent(nakama_client(), _state.notification_ids)
	_state.notification_ids = {}
	MPAPI.avatar_unlocked_toast:as_overlay()
end

local function forget_all()
	_state.queued = {}
	_state.queued_set = {}
	_state.notification_ids = {}
	_state.seen = {}
end

G.FUNCS.mpapi_avatar_unlocked_dismiss = function(e)
	G.FUNCS.exit_overlay_menu()
end

-----------------------------
-- TRIGGERS
-----------------------------

if notify then
	notify.on(notify.Code.AVATAR_UNLOCKED, function(content, notification)
		enqueue(content, notification and notification.persistent and notification.id or nil)
	end)
end

-- At login: what was earned while offline.
C.state_change_callbacks = C.state_change_callbacks or {}
table.insert(C.state_change_callbacks, function(new_state, context)
	local old_state = context and context.old_state
	if new_state == MPAPI.ConnectionState.CONNECTED and old_state ~= nil and old_state ~= new_state then
		notify.list_persistent(nakama_client(), notify.Code.AVATAR_UNLOCKED, function(stored)
			for _, notification in ipairs(stored) do
				enqueue(notification.content_table, notification.id)
			end
		end)
	elseif new_state == MPAPI.ConnectionState.DISCONNECTED then
		-- Still stored server-side: the next login lists them again.
		forget_all()
	end
end)

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

MPAPI.avatar_unlocked_toast = MPAPI.ui_element(create_UIBox_avatar_unlocked_toast)

-- For tests: the queue as it stands, and a way to feed it.
MPAPI._internal.avatar_unlocked_toast = {
	queued = function()
		return _state.queued
	end,
	enqueue = enqueue,
	can_show_now = can_show_now,
	reset = forget_all,
}
