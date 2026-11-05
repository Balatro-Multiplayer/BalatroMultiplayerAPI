-- The wording of each Notification kind. The server stores a kind and its
-- params (BalatroMultiplayerServer nakama/src/notification/kinds.ts); the
-- text lives here so it can be localized. A new event registers its kind
-- with a function params -> text. The same text is the chat line and the
-- login overlay.
local Kinds = {}
local describers = {}

function Kinds.register(kind, describe)
	describers[kind] = describe
end

-- The text for a Notification, or nil for a kind this client does not know
-- (a newer server): it is left unread for a client that does.
function Kinds.describe(kind, params)
	local describe = describers[kind]
	if not describe then
		return nil
	end
	local ok, text = pcall(describe, type(params) == 'table' and params or {})
	if ok and type(text) == 'string' and text ~= '' then
		return text
	end
	return nil
end

MPAPI.notification_kinds = Kinds
return Kinds
