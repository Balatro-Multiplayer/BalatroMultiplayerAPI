-- The one lifecycle-event dispatcher: mirrors SMODS/Balatro's calculate-context
-- pattern (a single `calculate(self, context)` per object, flag-checked context
-- table) instead of MPAPI inventing a differently-named hook per object type.
-- Participants are applied in increasing authority: layers, then the active
-- ruleset, then the active gamemode instance -- later participants override
-- earlier ones per-key in the merged return, matching the precedence already
-- established by layers/fields.lua and ruleset/current.lua (more specific
-- overrides less specific).

local function active_gamemode_instance()
	local lobby = MPAPI.get_current_lobby and MPAPI.get_current_lobby()
	if not lobby then return nil end
	return lobby:get_gamemode_instance()
end

function MPAPI.calculate_context(context)
	local result = {}

	local function apply(participant)
		if not participant or type(participant.calculate) ~= 'function' then return end
		local ret = participant:calculate(context)
		MPAPI._handle_gamemode_result(participant, ret)
		if type(ret) == 'table' then
			for k, v in pairs(ret) do
				result[k] = v
			end
		end
	end

	for _, name in ipairs(MPAPI.active_layer_chain()) do
		apply(MPAPI.Layers[name])
	end

	local ruleset_key = MPAPI.get_active_ruleset and MPAPI.get_active_ruleset()
	apply(ruleset_key and MPAPI.Rulesets[ruleset_key])

	apply(active_gamemode_instance())

	return result
end
