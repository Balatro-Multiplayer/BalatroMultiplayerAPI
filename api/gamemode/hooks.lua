-- Bridges lifecycle events into Balatro's run globals by wrapping the engine's
-- reset_blinds and ease_ante, dispatching through MPAPI.calculate_context so any
-- participant (layer, ruleset, gamemode) can react -- not just the gamemode
-- instance. Kept separate from the GameMode definition: this is the only place
-- that mutates G.* on the engine's behalf.

local function current_ante()
	return G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante
end

local function apply_blind_choices(choices)
	if choices.small then G.GAME.round_resets.blind_choices.Small = choices.small end
	if choices.big   then G.GAME.round_resets.blind_choices.Big   = choices.big   end
	if choices.boss  then G.GAME.round_resets.blind_choices.Boss  = choices.boss  end
end

local _orig_reset_blinds = reset_blinds
reset_blinds = function(...)
	local result = _orig_reset_blinds(...)
	local ante = current_ante()
	if ante then
		apply_blind_choices(MPAPI.calculate_context({ get_blinds = true, ante = ante }))
	end
	return result
end

local _orig_ease_ante = ease_ante
ease_ante = function(amt, ...)
	local result = _orig_ease_ante(amt, ...)
	local ante = current_ante()
	if ante then
		MPAPI.sendDebugMessage('ease_ante: amt=' .. tostring(amt) .. ' round_resets.ante=' .. tostring(ante) .. ' => firing with ' .. tostring(ante + amt))
		MPAPI.calculate_context({ ante_change = true, ante = ante + amt })
	end
	return result
end

-- Dispatches to the single active blind's calculate(self, context), same shape
-- as a Joker's calculate but with no per-instance "card" (a blind has none) and
-- no multi-participant merge (there's exactly one active blind). Consumer mods
-- call this at their own gameplay trigger points (hand played, discard, etc.)
-- instead of syncing the blind directly -- the blind's own calculate/send
-- decides what (if anything) to send, and to whom.
function MPAPI.calculate_blind(context)
	local blind = G.GAME and G.GAME.blind and G.GAME.blind.config and G.GAME.blind.config.blind
	if blind and type(blind.calculate) == 'function' then
		return blind:calculate(context)
	end
end
