-- Receives an Announcement (notify code 113): one chat line from the server,
-- sent to every online player at once and never stored. It prints in the menu
-- and in a lobby alike, through MPAPI.chat.addMessage.
local notify = MPAPI.networking.nakama_notify

local COLOUR_SYSTEM = { 1, 1, 0 }

local function receive(content)
	local text = type(content) == 'table' and content.text
	if type(text) ~= 'string' or text:match('^%s*$') then
		return
	end
	MPAPI.chat.addMessage(localize('k_notification_chat_prefix') .. ' ' .. text, COLOUR_SYSTEM)
end

if notify then
	notify.on(notify.Code.ANNOUNCEMENT, receive)
end
