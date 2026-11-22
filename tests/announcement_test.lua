-- Contract test: an Announcement (notify code 113) prints once as a [Server]
-- chat line, and a blank or malformed one prints nothing. Run from the MPAPI
-- repository root: luajit tests/announcement_test.lua
local T = dofile('tests/support.lua')
local check = T.check

localize = function(key)
	return key == 'k_notification_chat_prefix' and '[Server]' or key
end
local chat, handlers = {}, {}
MPAPI = {
	chat = {
		addMessage = function(text, colour)
			chat[#chat + 1] = { text = text, colour = colour }
		end,
	},
	networking = {
		nakama_notify = {
			Code = { ANNOUNCEMENT = 113 },
			on = function(code, fn)
				handlers[code] = fn
			end,
		},
	},
}

dofile('api/notification/announcement.lua')
check(type(handlers[113]) == 'function', 'code 113 has a handler')

handlers[113]({ text = 'Ranked is closed for a server update.' })
check(#chat == 1, 'an Announcement prints one chat line')
check(chat[1].text == '[Server] Ranked is closed for a server update.', 'the line has the server prefix and the text')

handlers[113]({ text = '   ' })
handlers[113]({ text = 5 })
handlers[113]({})
handlers[113]('nope')
check(#chat == 1, 'blank and malformed content prints nothing')

T.done('announcement_test')
