-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- Copied from WilsontheWolf/DebugPlus on 2026-03-30. See README.md for modifications.
-- Stripped to only the functions required by ui.lua and console.lua.

local global = {}
local isMac = love.system.getOS() == 'OS X'
global.ctrlText = isMac and "CMD" or "CTRL"

if isMac then
	function global.isCtrlDown()
		return love.keyboard.isDown('lgui') or love.keyboard.isDown('rgui') or love.keyboard.isDown('lctrl') or love.keyboard.isDown('rctrl')
	end
else
	function global.isCtrlDown()
		return love.keyboard.isDown('lctrl') or love.keyboard.isDown('rctrl')
	end
end

function global.isShiftDown()
	return love.keyboard.isDown('lshift') or love.keyboard.isDown('rshift')
end

function global.trim(string)
	return string:match("^%s*(.-)%s*$")
end

return global
