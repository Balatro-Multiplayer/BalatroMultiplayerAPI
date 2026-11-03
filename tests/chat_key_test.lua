-- Contract test for the configurable chat key: the saved key falls back to 't',
-- a pending rebind only holds while the Chat Key button is on screen, and only
-- a single allowed key is saved. Run from the MPAPI repository root:
-- luajit tests/chat_key_test.lua
local checks = 0
local function check(condition, message)
	checks = checks + 1
	assert(condition, message)
end

local saved, refreshed = nil, 0
MPAPI = {
	config = {},
	_internal = {
		config_set = function(key, value)
			MPAPI.config[key] = value
			saved = value
		end,
		refresh_account_overlay = function() refreshed = refreshed + 1 end,
	},
	load_mpapi_file = function() return {} end,
}
G = { E_MANAGER = { add_event = function() end } }
Event = function(t) return t end
dofile('api/chat.lua')
local chat = MPAPI.chat

local with_button = { get_UIE_by_ID = function(_, id) return id == chat.REBIND_BUTTON_ID and {} or nil end }
local without_button = { get_UIE_by_ID = function() return nil end }

local function arm(overlay)
	G.OVERLAY_MENU = overlay
	chat.rebinding = true
	saved, refreshed = nil, 0
end

-- get_key falls back to 't' and lower-cases a hand-edited value
MPAPI.config.chat_key = nil
check(chat.get_key() == 't', 'nil falls back to t')
MPAPI.config.chat_key = 5
check(chat.get_key() == 't', 'a number falls back to t')
MPAPI.config.chat_key = ''
check(chat.get_key() == 't', 'an empty string falls back to t')
MPAPI.config.chat_key = 'G'
check(chat.get_key() == 'g', 'an upper-case value is lower-cased')

-- not armed: the press is left alone
G.OVERLAY_MENU = with_button
chat.rebinding = false
saved = nil
check(chat.capture_key('g') == false and saved == nil, 'an unarmed press is not captured')

-- armed with the button on screen: a single key is saved and the overlay redrawn
arm(with_button)
check(chat.capture_key('g') == true, 'the press is consumed')
check(saved == 'g' and chat.rebinding == false, 'the key is saved and the rebind ends')
check(refreshed == 1, 'the account overlay is refreshed once')

for _, rejected in ipairs({ '/', 'r', 'escape', 'space' }) do
	arm(with_button)
	check(chat.capture_key(rejected) == true, rejected .. ' is consumed')
	check(saved == nil and chat.rebinding == false, rejected .. ' is not saved and ends the rebind')
end

-- armed but the button is gone: the press goes through and the rebind ends
arm(nil)
check(chat.capture_key('h') == false and saved == nil and chat.rebinding == false, 'no overlay: not captured, flag cleared')
arm(true)
check(chat.capture_key('h') == false and chat.rebinding == false, 'a boolean overlay: not captured, flag cleared')
arm(without_button)
check(chat.capture_key('h') == false and saved == nil and chat.rebinding == false, 'another overlay: not captured, flag cleared')
check(refreshed == 0, 'no refresh when nothing was captured')

print(('ok   %d checks'):format(checks))
