-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- Copied from WilsontheWolf/DebugPlus on 2026-03-30. See README.md for modifications.

local util = require "lib.debugplus.util"
local ui = require "lib.debugplus.ui"

local global = {}

local showTime = 5 -- seconds new messages are fully visible when console is closed
local fadeTime = 1 -- seconds a message takes to fade out

local consoleOpen = false
local openNextFrame = false
local gameKeyRepeat = love.keyboard.hasKeyRepeat()
local gameTextInput = love.keyboard.hasTextInput()
local initialized = false
local logOffset = 0

local messages = {}
local sendCallback = nil

local input = ui.TextInput.new(0)

local function closeConsole()
	input:clear()
	consoleOpen = false
	love.keyboard.setKeyRepeat(gameKeyRepeat)
	love.keyboard.setTextInput(gameTextInput)
end

local function sendMessage()
	local text = util.trim(input:toString())
	if text == "" then return end
	input:clear()
	closeConsole()
	if sendCallback then
		sendCallback(text)
	end
end

local orig_keypressed
local function consoleHandleKey(key, scancode, isrepeat)
	if not consoleOpen then
		if key == 't' then
			openNextFrame = true
		end
		if orig_keypressed then
			return orig_keypressed(key, scancode, isrepeat)
		end
		return true
	end

	if key == "escape" then
		closeConsole()
	end

	if key == "return" then
		sendMessage()
	end

	if key == "v" and util.isCtrlDown() then
		input:textinput(love.system.getClipboardText())
	end

	input:keypressed(key)
end

local orig_textinput
local function textinput(t)
	if not consoleOpen then
		if orig_textinput then orig_textinput(t) end
		return
	end
	input:textinput(t)
end

local orig_wheelmoved
local function wheelmoved(x, y)
	if not consoleOpen then
		if orig_wheelmoved then orig_wheelmoved(x, y) end
		return
	end
	logOffset = math.min(math.max(logOffset + y, 0), #messages - 1)
end

local function hookStuffs()
	orig_textinput = love.textinput
	love.textinput = textinput

	orig_wheelmoved = love.wheelmoved
	love.wheelmoved = wheelmoved

	orig_keypressed = love.keypressed
	love.keypressed = consoleHandleKey
end

local function calcHeight(text, width)
	local font = love.graphics.getFont()
	local rw, lines = font:getWrap(text, width)
	local lineHeight = font:getHeight()
	return #lines * lineHeight, rw, lineHeight
end

function global.doConsoleRender()
	if openNextFrame then
		consoleOpen = true
		openNextFrame = false
		logOffset = 0
		gameKeyRepeat = love.keyboard.hasKeyRepeat()
		gameTextInput = love.keyboard.hasTextInput()
		love.keyboard.setKeyRepeat(true)
		love.keyboard.setTextInput(true)
	end

	if not initialized then
		hookStuffs()
		initialized = true
	end

	if not consoleOpen and #messages == 0 then return end

	local width, height = love.graphics.getDimensions()
	local padding = 10
	local lineWidth = width - padding * 2
	local bottom = height - padding * 2
	local now = love.timer.getTime()

	-- Input box
	if consoleOpen then
		bottom = bottom - padding * 2
		input:setWidth(lineWidth - padding * 2)
		local inputHeight = input:getHeight()
		love.graphics.setColor(0, 0, 0, .5)
		love.graphics.rectangle("fill", padding, bottom - inputHeight + padding, lineWidth, inputHeight + padding * 2)
		love.graphics.setColor(1, 1, 1, 1)
		input:draw(padding * 2, bottom - inputHeight + padding * 2)
		bottom = bottom - inputHeight - padding
	end

	-- Main message window background
	if consoleOpen then
		love.graphics.setColor(0, 0, 0, .5)
		love.graphics.rectangle("fill", padding, padding, lineWidth, bottom)
	end

	-- Messages (rendered bottom-up)
	for i = #messages, 1, -1 do
		local v = messages[i]
		if consoleOpen and #messages - logOffset < i then
			goto continue
		end
		local age = now - v.time
		if not consoleOpen and age > showTime + fadeTime then
			break
		end
		local lineHeight = calcHeight(v.str, lineWidth)
		bottom = bottom - lineHeight
		if bottom < padding then
			break
		end

		local opacityPercent = 1
		if not consoleOpen and age > showTime then
			opacityPercent = (fadeTime - (age - showTime)) / fadeTime
		end

		if not consoleOpen then
			love.graphics.setColor(0, 0, 0, .5 * opacityPercent)
			love.graphics.rectangle("fill", padding, bottom, lineWidth, lineHeight)
		end
		love.graphics.setColor(v.colour[1], v.colour[2], v.colour[3], opacityPercent)
		love.graphics.printf(v.str, padding * 2, bottom, lineWidth - padding * 2)
		::continue::
	end
end

function global.addMessage(str, colour)
	table.insert(messages, {
		str = str,
		time = love.timer.getTime(),
		colour = colour or { 1, 1, 1 },
	})
	if #messages > 500 then
		table.remove(messages, 1)
	end
end

function global.setSendCallback(fn)
	sendCallback = fn
end

function global.isOpen()
	return consoleOpen
end

return global
