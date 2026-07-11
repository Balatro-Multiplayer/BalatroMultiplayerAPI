-- Synced GameObject core: the sync mixin (methods spread onto MPAPI.Blind/Joker/Consumable)
-- and the per-mod "sync bus" — one ActionType per consumer mod that all synced objects share,
-- demuxed by object key. Authors only ever touch self:sync / on_sync / sync_request; everything
-- below (ActionType creation, ownership, per-lobby routing, self-echo) is hidden.

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

-- Runs on every client that receives a bus frame. Demuxes to the target object; self-echo
-- (a frame we broadcast ourselves, looped back) is suppressed for sync/phantom, while a
-- 'request' returns a value that the ActionType response path ships back to the requester.
local function demux(_action_type, from, p)
	if not p or not p.obj then return end
	local obj = resolve(p.obj)
	if not obj then return end
	if p.kind == 'request' then
		if obj.on_sync_request then
			return { data = obj:on_sync_request(from, p.data) }
		end
		return
	end
	if from == self_id() then return end -- suppress our own broadcast loopback
	if p.kind == 'sync' then
		if obj.on_sync then obj:on_sync(from, p.data) end
	elseif p.kind == 'phantom' then
		if MPAPI._internal.phantom_apply then MPAPI._internal.phantom_apply(obj, p.data) end
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

-- Broadcast a raw bus frame from an object (shared by :sync and the phantom wiring).
local function broadcast_raw(obj, kind, data)
	local lobby = MPAPI.get_current_lobby()
	local bus = MPAPI._internal.sync_bus[obj.mod and obj.mod.id]
	if not (lobby and bus) then return end
	lobby:action(bus):broadcast({ obj = obj.key, kind = kind, data = data })
end
MPAPI._internal.sync_broadcast = broadcast_raw

-- Methods spread onto every synced GameObject class. `self` is the center object.
MPAPI._internal.synced_mixin = {
	-- Broadcast `data` to all other players; each runs on_sync(self, from, data).
	sync = function(self, data)
		broadcast_raw(self, 'sync', data)
	end,

	-- Ask one player for something: runs on_sync_request(self, from, data) on the target,
	-- whose return value comes back to on_sync_response(self, from, response) here.
	sync_request = function(self, target_id, data)
		local lobby = MPAPI.get_current_lobby()
		local bus = MPAPI._internal.sync_bus[self.mod and self.mod.id]
		if not (lobby and bus and target_id) then return end
		local obj = self
		-- The response callback is invoked as (instance, response_params); the demux wraps
		-- on_sync_request's return as { data = ... }.
		lobby:action(bus)
			:callback(function(_instance, resp)
				if obj.on_sync_response then obj:on_sync_response(target_id, resp and resp.data) end
			end)
			:send(target_id, { obj = self.key, kind = 'request', data = data })
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
	if obj.on_sync or obj.phantom or obj.on_sync_request then
		MPAPI._internal.get_sync_bus()
	end
	if obj.phantom and MPAPI._internal.wire_phantom then
		MPAPI._internal.wire_phantom(obj)
	end
end
