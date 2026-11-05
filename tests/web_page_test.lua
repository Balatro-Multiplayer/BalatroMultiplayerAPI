-- Contract test: MPAPI.open_web_page opens a website page through the server's
-- one-time login link, and falls back to the plain page address (a normal
-- login) when no link can be had. Run from the MPAPI repository root:
-- luajit tests/web_page_test.lua
local function check(condition, message)
	assert(condition, message)
end

local opened = {}
love = { system = { openURL = function(url) opened[#opened + 1] = url end } }

local link_reply
local asked = {}
MPAPI = {
	_internal = {
		get_web_login_url = function(path, callback)
			asked[#asked + 1] = path
			callback(link_reply.err, link_reply.data)
		end,
	},
	get_web_url = function() return 'https://site.test' end,
	ErrorKind = { SERVER = 'server' },
	sendWarnMessage = function() end,
	sendDebugMessage = function() end,
}
dofile('api/web_page.lua')

link_reply = { data = { url = 'https://site.test/auth/link?code=abc' } }
MPAPI.open_web_page('/matches/r1')
check(asked[1] == '/matches/r1', 'asks the server for the named page')
check(opened[1] == 'https://site.test/auth/link?code=abc', 'opens the one-time link')

link_reply = { err = 'Not connected' }
MPAPI.open_web_page('/matches/r2')
check(opened[2] == 'https://site.test/matches/r2', 'falls back to the plain page when no link comes')

link_reply = { data = {} }
MPAPI.open_web_page('/matches/r3')
check(opened[3] == 'https://site.test/matches/r3', 'falls back when the reply has no url')

local before = #opened
MPAPI.open_web_page('https://evil.example/x')
MPAPI.open_web_page('//evil.example')
MPAPI.open_web_page(nil)
check(#opened == before and #asked == 3, 'never opens a page that is not a path on the site')

MPAPI.get_web_url = function() return nil end
link_reply = { err = 'x' }
MPAPI.open_web_page('/profile')
check(#opened == before, 'opens nothing when the website address is unknown')

print('web_page_test: ok')
