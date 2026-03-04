-- Animated multiplayer edition colour
-- Drifts between violet and magenta within the purple family
MPAPI.C = MPAPI.C or {}
MPAPI.C.MP_EDITION = {0.55, 0.30, 0.70, 1}

local _game_update_ref = Game.update
function Game:update(dt)
    _game_update_ref(self, dt)
    local t = self.TIMERS.REAL
    local c = MPAPI.C.MP_EDITION
    local s = math.sin(t * 0.7)
    c[1] = 0.72 + 0.08 * s
    c[2] = 0.45 + 0.05 * s
    c[3] = 0.64 - 0.08 * s
end

function MPAPI.Disableable_Button(args)
	local enabled_table = args.enabled_ref_table or {}
	local enabled = enabled_table[args.enabled_ref_value]
	args.colour = args.colour or G.C.RED
	args.text_colour = args.text_colour or G.C.UI.TEXT_LIGHT
	args.disabled_text = args.disabled_text or args.label
	args.label = not enabled and args.disabled_text or args.label

	local button_component = UIBox_button(args)
	button_component.nodes[1].config.button = enabled and args.button or nil
	button_component.nodes[1].config.hover = enabled
	button_component.nodes[1].config.shadow = enabled
	button_component.nodes[1].config.colour = enabled and args.colour or G.C.UI.BACKGROUND_INACTIVE
	button_component.nodes[1].nodes[1].nodes[1].colour = enabled and args.text_colour or G.C.UI.TEXT_INACTIVE
	button_component.nodes[1].nodes[1].nodes[1].shadow = enabled
	return button_component
end