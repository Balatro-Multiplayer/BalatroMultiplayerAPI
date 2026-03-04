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
