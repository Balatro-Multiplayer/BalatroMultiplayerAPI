-- Synced GameObject core: the sync mixin (methods spread onto MPAPI.Blind/Joker/Consumable)
-- and the per-mod "sync bus" — one ActionType per consumer mod that all synced objects share,
-- demuxed by object key. Mirrors SMODS's calculate(self, card, context) pattern fully, not just
-- its dispatch shape: objects never call side-effecting network APIs themselves. Outbound intent
-- is declared via a `send` key in a return table (from the object's own calculate, wrapped in
-- objects.lua, or from `receive`'s own return -- a reply is just another send); this file is the
-- only place that actually broadcasts anything. `send(self, card, value)` is an optional per-
-- object transform (defaults to identity) between "what calculate/receive declared" and "what
-- goes on the wire". Request/response is not a transport primitve -- it's just two broadcasts,
-- with any request/response distinction left entirely to the payload's own shape, handled by the
-- same `receive` on both ends.

MPAPI._internal = MPAPI._internal or {}
MPAPI._internal.sync_bus = MPAPI._internal.sync_bus or {}

local function self_id()
	local lobby = MPAPI.get_current_lobby()
	return lobby and lobby.player_id
end

-- A synced object's key resolves to its live center (blind or card center).
local function resolve(obj_key)
	return (G.P_BLINDS and G.P_BLINDS[obj_key]) or (G.P_CENTERS and G.P_CENTERS[obj_key])
end

-- Broadcast a raw bus frame from an object (shared by perform_send and the phantom wiring).
local function broadcast_raw(obj, kind, data)
	local lobby = MPAPI.get_current_lobby()
	local bus = MPAPI._internal.sync_bus[obj.mod and obj.mod.id]
	if not (lobby and bus) then return end
	lobby:action(bus):broadcast({ obj = obj.key, kind = kind, data = data })
end
MPAPI._internal.sync_broadcast = broadcast_raw

-- The one place a `send` declaration actually goes out on the wire. `card` is the
-- live card when triggered from a calculate return, nil when triggered from a
-- receive reply (receive is center-scoped, same as before).
function MPAPI._internal.perform_send(obj, card, value)
	local payload = value
	if type(obj.send) == 'function' then
		payload = obj:send(card, value)
	end
	broadcast_raw(obj, 'sync', payload)
end

-- Runs on every client that receives a bus frame. Demuxes to the target object; self-echo
-- (a frame we broadcast ourselves, looped back) is suppressed for sync/phantom. `receive`
-- can itself return { send = value } to reply -- e.g. a request/response exchange is just
-- two of these round trips, distinguished by whatever shape the payload's author gives it.
local function demux(_action_type, from, p)
	if not p or not p.obj then return end
	local obj = resolve(p.obj)
	if not obj then return end
	if p.kind == 'phantom' then
		if MPAPI._internal.phantom_apply then MPAPI._internal.phantom_apply(obj, p.data) end
		return
	end
	if from == self_id() then return end -- suppress our own broadcast loopback
	if p.kind == 'sync' and obj.receive then
		local ret = obj:receive({ from = from, data = p.data })
		if type(ret) == 'table' and ret.send ~= nil then
			MPAPI._internal.perform_send(obj, nil, ret.send)
		end
	end
end

-- Lazily create/return the sync bus owned by the mod currently being loaded. Called at
-- object-definition time (SMODS.current_mod = the consumer, before any lobby exists), so the
-- ActionType is tagged to the consumer and lands in the per-lobby routing snapshot.
function MPAPI._internal.get_sync_bus()
	local mod = SMODS.current_mod
	local mod_id = mod and mod.id
	if not mod_id then return nil end
	if MPAPI._internal.sync_bus[mod_id] then return MPAPI._internal.sync_bus[mod_id] end
	local bus = MPAPI.ActionType({
		key = 'mpapi_sync',
		parameters = {
			{ key = 'obj', type = 'string', required = true },
			{ key = 'kind', type = 'string', required = true },
		},
		on_receive = demux,
	})
	MPAPI._internal.sync_bus[mod_id] = bus
	return bus
end

-- Methods spread onto every synced GameObject class. `self` is the center object.
MPAPI._internal.synced_mixin = {
	-- Broadcast `data` to all other players; each runs receive({from=..., data=...}).
	-- Stays public: the primitive perform_send/broadcast_raw build on, for any trigger
	-- that doesn't go through the object's own calculate.
	sync = function(self, data)
		broadcast_raw(self, 'sync', data)
	end,

	-- Wraps the consumer's real calculate (captured as _user_calculate by objects.lua,
	-- since a plain instance field would otherwise shadow this class-level method).
	-- If the return has a `send` key, performs it and strips it before returning the
	-- rest untouched to Balatro's own scoring engine.
	calculate = function(self, card, context)
		local ret = self._user_calculate and self:_user_calculate(card, context)
		if type(ret) == 'table' and ret.send ~= nil then
			MPAPI._internal.perform_send(self, card, ret.send)
			ret.send = nil
		end
		return ret
	end,

	-- Per-remote-player scratch store (framework-managed). N-player content keys off `from`.
	remote = function(self, from)
		self._remotes = self._remotes or {}
		self._remotes[from] = self._remotes[from] or {}
		return self._remotes[from]
	end,

	-- 1v1 convenience: the single other player's id / remote store.
	opponent_id = function(self)
		local lobby = MPAPI.get_current_lobby()
		if not lobby then return nil end
		for _, pl in ipairs(lobby:get_players()) do
			if pl.id ~= lobby.player_id then return pl.id end
		end
		return nil
	end,
	opponent = function(self)
		local id = self:opponent_id()
		return id and self:remote(id) or self:remote('?')
	end,
}

-- Called by the MPAPI.Blind/Joker/Consumable wrappers right after a synced object registers
-- (still inside the consumer's load, SMODS.current_mod correct): ensure the bus exists and
-- wire phantom copies if declared.
function MPAPI._internal.on_synced_registered(obj)
	if obj.receive or obj._user_calculate or obj.phantom then
		MPAPI._internal.get_sync_bus()
	end
	if obj.phantom and MPAPI._internal.wire_phantom then
		MPAPI._internal.wire_phantom(obj)
	end
end
