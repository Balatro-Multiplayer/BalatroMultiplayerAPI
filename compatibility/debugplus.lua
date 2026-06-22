-- BalatroMultiplayerAPI — DebugPlus compatibility layer
-- Hooks into DebugPlus's console so BMP chat messages appear there and
-- bare text (no leading /) is sent as chat instead of a DP command.
-- T is added as an alias for / to open the console.

local M = {}

local COLOUR_OWN = { 0.65, 0.36, 1 }
local COLOUR_SYSTEM = { 1, 1, 0 }

local dp = nil -- DebugPlus registered mod object
local dp_log = nil -- raw DebugPlus logger (no [BMP] prefix); set after patching

local dp_patched = false
local pending_msgs = {} -- queued before dp_log is available

-- Placeholder until patching runs and sets dp_console.isConsoleFocused
M.isOpen = function()
	return false
end

-- Set by chat.lua when a lobby publish function is active
M.send_fn = nil

-----------------------------
-- INTERNALS
-----------------------------

local function get_upvalue(fn, target)
	local i = 1
	while true do
		local name, val = debug.getupvalue(fn, i)
		if not name then
			return nil
		end
		if name == target then
			return val
		end
		i = i + 1
	end
end

-- Called on the first frame after DP's hookStuffs has run.
-- orig_render is the real doConsoleRender (upvalues: input, logger, etc.).
-- dp_console.doConsoleRender may already be our wrapper at call time, so we
-- must search orig_render's upvalues, not dp_console.doConsoleRender's.
local function patch(dp_console, orig_render)
	local input_widget = get_upvalue(orig_render, 'input')
	if not input_widget then
		MPAPI.sendWarnMessage('chat/debugplus: could not find input widget — DP integration disabled')
		return false
	end

	dp_log = get_upvalue(orig_render, 'logger')
	if not dp_log then
		MPAPI.sendWarnMessage('chat/debugplus: could not find internal logger, using API logger (messages will have [BMP] prefix)')
		dp_log = {
			handleLog = function(colour, level, str)
				dp.logger.info(str)
			end,
		}
	end

	M.isOpen = dp_console.isConsoleFocused

	-- Flush any messages that arrived before patching
	for _, msg in ipairs(pending_msgs) do
		dp_log.handleLog(msg.colour, 'INFO', msg.str)
	end
	pending_msgs = {}

	local dp_keypressed = love.keypressed
	love.keypressed = function(key, scancode, isrepeat)
		-- T opens the DP console (alias for /)
		if key == 't' and not dp_console.isConsoleFocused() then
			dp_keypressed('/', '/', false)
			return
		end

		if key == 'return' and dp_console.isConsoleFocused() then
			local text = input_widget:toString():match('^%s*(.-)%s*$')
			if text ~= '' then
				if text:sub(1, 1) ~= '/' then
					-- No / prefix → send as chat
					if M.send_fn then
						M.send_fn(text)
					else
						M.addMessage(localize('k_chat_not_enabled'), COLOUR_SYSTEM)
					end
					dp_keypressed('escape', 'escape', false)
					return
				else
					-- / prefix → strip it, let DP execute as a command
					input_widget:set(text:sub(2))
				end
			end
		end

		return dp_keypressed(key, scancode, isrepeat)
	end

	return true
end

local function ensure_patched()
	if dp_patched then
		return
	end

	local ok, dp_console = pcall(require, 'debugplus.console')
	if not ok then
		MPAPI.sendWarnMessage('chat/debugplus: could not require debugplus.console: ' .. tostring(dp_console))
		return
	end

	local orig_render = dp_console.doConsoleRender
	dp_console.doConsoleRender = function()
		orig_render()
		if not dp_patched then
			dp_patched = true -- always stop retrying, even on failure
			if patch(dp_console, orig_render) then
				dp_console.doConsoleRender = orig_render -- restore; wrapper no longer needed
			end
		end
	end
end

-----------------------------
-- PUBLIC API
-----------------------------

-- Call once at game start (after all mods are loaded).
-- Returns true if DebugPlus is available and this module is active.
function M.init()
	local dp_ok, dpAPI = pcall(require, 'debugplus-api')
	local available = dp_ok and type(dpAPI) == 'table' and type(dpAPI.isVersionCompatible) == 'function' and dpAPI.isVersionCompatible(1)

	if not available then
		return false
	end

	dp = dpAPI.registerID('BMP')
	ensure_patched()
	return true
end

function M.addMessage(str, colour)
	if dp_log then
		dp_log.handleLog(colour, 'INFO', str)
	else
		table.insert(pending_msgs, { str = str, colour = colour })
	end
end

return M
