-- The avatar catalog: every avatar, whether this player has unlocked it, and
-- its unlock goal. The server is the source (the avatar_catalog RPC,
-- BalatroMultiplayerServer nakama/src/achievements/rpc.ts); this caches its
-- answer for the picker and the Achievements tab.
--
-- Fetched when the connection comes up, refreshed on ACCOUNT_UPDATED (101) and
-- AVATAR_UNLOCKED (107), dropped on disconnect. A server without the RPC (an
-- older one) gets a fallback catalog: the current avatar, j_joker and the
-- privilege jokers, all pickable.
MPAPI.avatars = MPAPI.avatars or {}
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn
local Catalog = {}

local DEFAULT_AVATAR = 'j_joker'

-- Where the shown catalog came from.
Catalog.Source = {
	SERVER = 'server',
	FALLBACK = 'fallback',
}

Catalog.Status = {
	-- Nothing fetched (not connected yet, or disconnected).
	EMPTY = 'empty',
	LOADING = 'loading',
	READY = 'ready',
	-- The RPC failed or is missing: the fallback catalog is shown.
	FALLBACK = 'fallback',
}

Catalog.ParseError = {
	NOT_A_TABLE = 'not_a_table',
	NO_AVATARS = 'no_avatars',
}

-----------------------------
-- PURE
-----------------------------

local function index_by_id(avatars)
	local by_id = {}
	for i, entry in ipairs(avatars) do
		by_id[entry.id] = i
	end
	return by_id
end

local function parse_goal(goal)
	if type(goal) ~= 'table' or type(goal.kind) ~= 'string' then
		return nil
	end
	return {
		kind = goal.kind,
		key = goal.key ~= nil and tostring(goal.key) or '',
		threshold = tonumber(goal.threshold) or 1,
		progress = tonumber(goal.progress) or 0,
	}
end

-- The RPC's answer as a catalog, or nil and a Catalog.ParseError. Entries
-- without an id are dropped; order is kept (it is the display order).
function Catalog.parse(data)
	if type(data) ~= 'table' then
		return nil, Catalog.ParseError.NOT_A_TABLE
	end
	if type(data.avatars) ~= 'table' then
		return nil, Catalog.ParseError.NO_AVATARS
	end
	local avatars = {}
	for _, raw in ipairs(data.avatars) do
		if type(raw) == 'table' and type(raw.id) == 'string' then
			avatars[#avatars + 1] = {
				id = raw.id,
				unlocked = raw.unlocked == true,
				goal = parse_goal(raw.goal),
			}
		end
	end
	if #avatars == 0 then
		return nil, Catalog.ParseError.NO_AVATARS
	end
	return {
		source = Catalog.Source.SERVER,
		avatars = avatars,
		by_id = index_by_id(avatars),
		selected = type(data.selected) == 'string' and data.selected or DEFAULT_AVATAR,
		enabled = data.enabled ~= false,
	}
end

-- What an older server allows: j_joker, the current avatar and the privilege
-- jokers, all unlocked and goal-less.
function Catalog.fallback(selected, privilege_jokers)
	selected = type(selected) == 'string' and selected or DEFAULT_AVATAR
	local ids = MPAPI.merge_unique({ DEFAULT_AVATAR, selected }, privilege_jokers or {})
	local avatars = {}
	for _, id in ipairs(ids) do
		avatars[#avatars + 1] = { id = id, unlocked = true, goal = nil }
	end
	return {
		source = Catalog.Source.FALLBACK,
		avatars = avatars,
		by_id = index_by_id(avatars),
		selected = selected,
		enabled = true,
	}
end

function Catalog.find(catalog, id)
	local i = catalog and catalog.by_id[id]
	return i and catalog.avatars[i] or nil
end

function Catalog.unlocked_count(catalog)
	local n = 0
	for _, entry in ipairs(catalog and catalog.avatars or {}) do
		if entry.unlocked then
			n = n + 1
		end
	end
	return n
end

-- The catalog with `id` as the selection (a pick the server accepted).
function Catalog.with_selected(catalog, id)
	local copy = {}
	for k, v in pairs(catalog) do
		copy[k] = v
	end
	copy.selected = id
	return copy
end

-----------------------------
-- CACHE
-----------------------------

local _cache = {
	status = Catalog.Status.EMPTY,
	catalog = nil,
	-- Callbacks waiting on the fetch in flight, and whether another fetch was
	-- asked for meanwhile (news may have arrived after the request went out).
	waiting = {},
	again = false,
	-- Bumped on disconnect, so an answer for an old session is ignored.
	generation = 0,
}
local _listeners = {}

local function connected_connection()
	local conn = C.connection
	if conn and conn:get_state() == MPAPI.ConnectionState.CONNECTED and conn.session_token then
		return conn
	end
	return nil
end

local function current_fallback()
	local privileges = MPAPI.connection_state.privileges
	return Catalog.fallback(MPAPI.connection_state.preferred_joker, privileges and privileges.jokers)
end

local function announce()
	for _, fn in ipairs(_listeners) do
		local ok, err = pcall(fn, _cache.catalog, _cache.status)
		if not ok then
			MPAPI.sendWarnMessage('[avatars] catalog listener failed: ' .. tostring(err))
		end
	end
end

local function settle(err)
	local waiting = _cache.waiting
	_cache.waiting = {}
	announce()
	for _, cb in ipairs(waiting) do
		pcall(cb, err, _cache.catalog)
	end
end

-- fn(catalog, status) after every change (fetched, fell back, cleared).
function Catalog.on_change(fn)
	_listeners[#_listeners + 1] = fn
end

function Catalog.status()
	return _cache.status
end

-- Whether a catalog (fetched or fallback) is held, as opposed to the one
-- get() would build on the spot.
function Catalog.has_catalog()
	return _cache.catalog ~= nil
end

-- The catalog to show: the cached one, or the fallback built from the
-- connection while nothing has been fetched.
function Catalog.get()
	return _cache.catalog or current_fallback()
end

-- Fetches the catalog. cb(err, catalog) once it has settled; err is an
-- MPAPI error, and the fallback catalog is in place when the fetch failed
-- with nothing fetched before. Calls during a fetch join it (and ask for one
-- more fetch after it).
function Catalog.refresh(cb)
	if cb then
		_cache.waiting[#_cache.waiting + 1] = cb
	end
	if _cache.status == Catalog.Status.LOADING then
		_cache.again = true
		return
	end
	local conn = connected_connection()
	if not conn then
		settle(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'))
		return
	end

	_cache.status = Catalog.Status.LOADING
	_cache.again = false
	local generation = _cache.generation
	conn:_nakama_rpc('avatar_catalog', {}, function(rpc_err, data)
		if generation ~= _cache.generation then
			return
		end
		local catalog, parse_err = nil, nil
		if not rpc_err then
			catalog, parse_err = Catalog.parse(data)
		end
		local err = nil
		if catalog then
			_cache.catalog = catalog
			_cache.status = Catalog.Status.READY
		else
			err = MPAPI.make_error(MPAPI.ErrorKind.SERVER, rpc_err or ('avatar_catalog: ' .. tostring(parse_err)))
			MPAPI.sendDebugMessage('[avatars] catalog unavailable, using the fallback: ' .. tostring(err.message))
			-- A fetch that worked before stays: one failed refresh shouldn't
			-- lock the picker down to the fallback.
			if _cache.catalog and _cache.catalog.source == Catalog.Source.SERVER then
				_cache.status = Catalog.Status.READY
			else
				_cache.catalog = current_fallback()
				_cache.status = Catalog.Status.FALLBACK
			end
		end
		if _cache.again then
			_cache.status = _cache.catalog.source == Catalog.Source.SERVER and Catalog.Status.READY or Catalog.Status.FALLBACK
			announce()
			Catalog.refresh()
			return
		end
		settle(err)
	end)
end

-- Records a pick the server accepted, before the refresh confirms it.
function Catalog.note_selected(id)
	if _cache.catalog then
		_cache.catalog = Catalog.with_selected(_cache.catalog, id)
		announce()
	end
end

function Catalog.clear()
	_cache.generation = _cache.generation + 1
	_cache.catalog = nil
	_cache.status = Catalog.Status.EMPTY
	_cache.again = false
	settle(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Disconnected'))
end

-----------------------------
-- TRIGGERS
-----------------------------

C.state_change_callbacks = C.state_change_callbacks or {}
table.insert(C.state_change_callbacks, function(new_state, context)
	-- Only a real transition carries old_state (a player_update or a
	-- reconnected-lobby notice re-fires CONNECTED without one).
	local connected = new_state == MPAPI.ConnectionState.CONNECTED
	local old_state = context and context.old_state
	if connected and old_state ~= nil and old_state ~= new_state then
		Catalog.refresh()
	elseif not connected and _cache.status ~= Catalog.Status.EMPTY then
		Catalog.clear()
	end
end)

do
	local notify = MPAPI.networking.nakama_notify
	if notify then
		notify.on(notify.Code.ACCOUNT_UPDATED, function()
			Catalog.refresh()
		end)
		notify.on(notify.Code.AVATAR_UNLOCKED, function()
			Catalog.refresh()
		end)
	end
end

MPAPI.avatars.catalog = Catalog
