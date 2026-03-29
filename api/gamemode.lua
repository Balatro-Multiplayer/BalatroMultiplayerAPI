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
