-----------------------------
-- GameMode registration
-----------------------------

MPAPI.GameModes = {}

MPAPI.GameMode = SMODS.GameObject:extend({
	obj_table = MPAPI.GameModes,
	obj_buffer = {},
	set = 'GameMode',
	has_ranked_mode = false,
	min_players = 2,
	max_players = 16,
	-- Whether the in-run "Seed Change" control is offered for this mode. Modes can
	-- set this false to hide the seed-change button entirely (e.g. best-of-N modes
	-- where re-rolling the seed would undermine the format).
	seed_change_allowed = true,
	required_params = { 'key', 'start_run' },

	inject = function(self)
		if type(self.min_players) == 'table' then
			assert(self.min_players.public ~= nil, 'GameMode ' .. self.key .. ': min_players table must have a public key')
			assert(self.min_players.private ~= nil, 'GameMode ' .. self.key .. ': min_players table must have a private key')
			if self.has_ranked_mode then
				assert(self.min_players.ranked ~= nil, 'GameMode ' .. self.key .. ': min_players table must have a ranked key when has_ranked_mode is true')
			end
		end

		if type(self.max_players) == 'table' then
			assert(self.max_players.public ~= nil, 'GameMode ' .. self.key .. ': max_players table must have a public key')
			assert(self.max_players.private ~= nil, 'GameMode ' .. self.key .. ': max_players table must have a private key')
			if self.has_ranked_mode then
				assert(self.max_players.ranked ~= nil, 'GameMode ' .. self.key .. ': max_players table must have a ranked key when has_ranked_mode is true')
			end
		end
	end,

	get_min_players = function(self, lobby_type)
		lobby_type = lobby_type or 'private'
		if type(self.min_players) == 'number' then
			return self.min_players
		end
		return self.min_players[lobby_type]
	end,

	get_max_players = function(self, lobby_type)
		lobby_type = lobby_type or 'private'
		if type(self.max_players) == 'number' then
			return self.max_players
		end
		return self.max_players[lobby_type]
	end,

	-- Elimination helper for last-player-standing modes. Records that `player_id`
	-- has forfeited (tracked on self._forfeited) and, when exactly one player in the
	-- current lobby is left un-forfeited, returns that survivor's id. Returns nil
	-- otherwise. Host-authoritative: only the host gets a non-nil result, so callers
	-- can broadcast their mode's "player won" action for the returned id without an
	-- extra host check.
	check_single_survivor = function(self, player_id)
		self._forfeited = self._forfeited or {}
		self._forfeited[player_id] = true

		local lobby = MPAPI.get_current_lobby()
		if not lobby or not lobby.is_host then
			return nil
		end

		local remaining = {}
		for _, p in ipairs(lobby:get_players()) do
			if not self._forfeited[p.id] then
				remaining[#remaining + 1] = p
			end
		end

		if #remaining == 1 then
			return remaining[1].id
		end
		return nil
	end,

	-- Creates a fresh per-run instance inheriting from this definition.
	-- GameModes can define init(self) to set up per-instance state.
	new_instance = function(self)
		local instance = setmetatable({}, { __index = self })
		if instance.init then
			instance:init()
		end
		return instance
	end,
})

-----------------------------
-- ease_ante hook
-----------------------------

-----------------------------
-- reset_blinds hook
-----------------------------

local _orig_reset_blinds = reset_blinds
reset_blinds = function(...)
	local result = _orig_reset_blinds(...)
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if not lobby then return result end
	local gm = lobby:get_gamemode_instance()
	if gm and gm.get_blinds_by_ante then
		local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
		if ante then
			local small, big, boss = gm:get_blinds_by_ante(ante)
			if small then G.GAME.round_resets.blind_choices.Small = small end
			if big   then G.GAME.round_resets.blind_choices.Big   = big   end
			if boss  then G.GAME.round_resets.blind_choices.Boss  = boss  end
		end
	end
	return result
end

-----------------------------
-- ease_ante hook
-----------------------------

local _orig_ease_ante = ease_ante
ease_ante = function(amt, ...)
	local result = _orig_ease_ante(amt, ...)
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if not lobby then
		return result
	end
	local gm = lobby:get_gamemode_instance()
	if gm and gm.on_ante_change then
		local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
		MPAPI.sendDebugMessage('ease_ante: amt=' .. tostring(amt) .. ' round_resets.ante=' .. tostring(ante) .. ' => firing with ' .. tostring(ante and (ante + amt)))
		if ante then
			gm:on_ante_change(ante + amt)
		end
	end
	return result
end
