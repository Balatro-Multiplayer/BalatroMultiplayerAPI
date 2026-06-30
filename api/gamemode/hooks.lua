-- Bridges the active GameMode instance into Balatro's run globals by wrapping the
-- engine's reset_blinds and ease_ante. Kept separate from the GameMode definition:
-- this is the only place that mutates G.* on the engine's behalf.

local function active_gamemode_instance()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if not lobby then
		return nil
	end
	return lobby:get_gamemode_instance()
end

local function current_ante()
	return G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
end

local function apply_blind_choices(small, big, boss)
	if small then G.GAME.round_resets.blind_choices.Small = small end
	if big   then G.GAME.round_resets.blind_choices.Big   = big   end
	if boss  then G.GAME.round_resets.blind_choices.Boss  = boss  end
end

local _orig_reset_blinds = reset_blinds
reset_blinds = function(...)
	local result = _orig_reset_blinds(...)
	local gm = active_gamemode_instance()
	if gm and gm.get_blinds_by_ante then
		local ante = current_ante()
		if ante then
			apply_blind_choices(gm:get_blinds_by_ante(ante))
		end
	end
	return result
end

local _orig_ease_ante = ease_ante
ease_ante = function(amt, ...)
	local result = _orig_ease_ante(amt, ...)
	local gm = active_gamemode_instance()
	if gm and gm.on_ante_change then
		local ante = current_ante()
		MPAPI.sendDebugMessage('ease_ante: amt=' .. tostring(amt) .. ' round_resets.ante=' .. tostring(ante) .. ' => firing with ' .. tostring(ante and (ante + amt)))
		if ante then
			gm:on_ante_change(ante + amt)
		end
	end
	return result
end
