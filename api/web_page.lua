-- Opening a website page from the game with the player already logged in. The
-- server gives a short-lived link that works once (rpc web_login_link, ADR
-- 0011); opening it logs the player in to the website and lands on the page.
-- Anything that opens a website page (match history, the report page, the
-- Contest page) goes through MPAPI.open_web_page.

local function is_site_path(path)
	return type(path) == 'string' and path:sub(1, 1) == '/' and path:sub(2, 2) ~= '/'
end

-- Opens `path` (a page of the website, "/matches/<runId>") in the browser. If
-- no login link can be had (offline, an older server), it opens the plain page
-- and the player logs in as usual.
function MPAPI.open_web_page(path)
	if not is_site_path(path) then
		return
	end
	local function open_plain()
		local base_url = MPAPI.get_web_url()
		if base_url then
			love.system.openURL(base_url .. path)
		end
	end
	MPAPI._internal.get_web_login_url(path, function(err, data)
		if err or not (data and type(data.url) == 'string') then
			MPAPI.sendWarnMessage('Web login link unavailable: ' .. tostring(err))
			open_plain()
			return
		end
		love.system.openURL(data.url)
	end)
end
