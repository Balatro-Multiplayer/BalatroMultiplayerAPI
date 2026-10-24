-- The account's queue standing (domain/standing.lua): what the server says
-- this session may queue for, worked out from the mod report that
-- api/connection/profile.lua sends on every login. Cached from the three
-- places the server says it: the profile_set_mods reply, the account_standing
-- RPC and the STANDING_CHANGED (108) push.
--
-- MPAPI.standing holds the pure rules (tested by ClaudeControl's
-- mpapi:standing suite); the cache and the server calls sit below them.
MPAPI._internal.conn = MPAPI._internal.conn or {}
local C = MPAPI._internal.conn

MPAPI.standing = MPAPI.standing or {}
local S = MPAPI.standing

local Standing = MPAPI.Standing
local Refusal = MPAPI.QueueRefusalCode
local Rejoin = MPAPI.RejoinRefusalCode

-- How many mods a refusal names before "and N more".
S.MODS_SHOWN = 4

local REJOIN_PREFIX = 'standing_refused:'

local function is_member(set, value)
	for _, v in pairs(set) do
		if v == value then
			return true
		end
	end
	return false
end

local function string_list(list)
	local out = {}
	for _, v in ipairs(type(list) == 'table' and list or {}) do
		if type(v) == 'string' then
			out[#out + 1] = v
		end
	end
	return out
end

-- A StandingView off the wire ({standing, disallowed, reason}), or
-- nil when it isn't one (an older server sends none). Pure.
function S.view_of(data)
	if type(data) ~= 'table' or not is_member(Standing, data.standing) then
		return nil
	end
	return {
		standing = data.standing,
		disallowed = string_list(data.disallowed),
		reason = is_member(MPAPI.StandingReason, data.reason) and data.reason or nil,
	}
end

-- Whether the account counts as verified: the server says so, or the
-- launcher verdict (105) landed after the view was taken. Pure.
function S.is_verified(view, launcher_verified)
	return launcher_verified == true or (view ~= nil and view.standing == Standing.VERIFIED)
end

-- The refusal for a standing that is none: {code, mods}. Pure.
local function none_refusal(view)
	if view.reason == MPAPI.StandingReason.UNREPORTED then
		return { code = Refusal.MODS_UNREPORTED, mods = {} }
	end
	return { code = Refusal.MODS_NOT_ALLOWED, mods = view.disallowed }
end

-- Why this account may not queue `kind` (MPAPI.QueueKind), or nil when it
-- may. view nil is an unknown standing (no reply yet, or an older server):
-- casual is let through and the server decides. Ranked always needs a
-- verified account, as before standings: the client can't see whether the
-- server enforces integrity. Pure.
function S.queue_refusal(view, kind, launcher_verified)
	if S.is_verified(view, launcher_verified) then
		return nil
	end
	if view ~= nil and view.standing == Standing.NONE then
		return none_refusal(view)
	end
	if kind == MPAPI.QueueKind.RANKED then
		return { code = Refusal.INTEGRITY_REQUIRED, mods = {} }
	end
	return nil
end

-- Whether the account meets a game's requiredStanding ('valid', 'verified'
-- or nil for a private lobby). An unknown standing meets 'valid': the server
-- has the last word on the join. Pure.
function S.meets(view, required, launcher_verified)
	if required == nil or S.is_verified(view, launcher_verified) then
		return true
	end
	if required == Standing.VERIFIED then
		return false
	end
	return view == nil or view.standing ~= Standing.NONE
end

-- Why the account can't rejoin a game needing `required`, or nil when it
-- can: {code (MPAPI.RejoinRefusalCode), mods}. Pure.
function S.rejoin_refusal(view, required, launcher_verified)
	if S.meets(view, required, launcher_verified) then
		return nil
	end
	if view ~= nil and view.standing == Standing.NONE then
		if view.reason == MPAPI.StandingReason.UNREPORTED then
			return { code = Rejoin.MODS_UNREPORTED, mods = {} }
		end
		return { code = Rejoin.MODS_NOT_ALLOWED, mods = view.disallowed }
	end
	return { code = Rejoin.VERIFICATION_PENDING, mods = {} }
end

-- A match_join error message parsed into the rejoin refusal it carries
-- (`standing_refused:` + JSON {reason, mods, message}), or nil when the
-- message is some other error. Pure.
function S.parse_rejoin_refusal(message)
	if type(message) ~= 'string' then
		return nil
	end
	local at = message:find(REJOIN_PREFIX, 1, true)
	if not at then
		return nil
	end
	local ok, data = pcall(MPAPI.json_decode, message:sub(at + #REJOIN_PREFIX))
	if not ok or type(data) ~= 'table' or not is_member(Rejoin, data.reason) then
		return nil
	end
	return { code = data.reason, mods = string_list(data.mods) }
end

-- "A, B, C, D and 2 more": the first MODS_SHOWN names.
function S.format_mods(names)
	local shown = {}
	for i = 1, math.min(#names, S.MODS_SHOWN) do
		shown[i] = names[i]
	end
	local text = table.concat(shown, ', ')
	local hidden = #names - #shown
	if hidden > 0 then
		text = text .. ' ' .. localize('k_mods_and_more'):gsub('#1#', tostring(hidden))
	end
	return text
end

-- Every mod key, by SMODS id, MODS_PER_LINE to a line: what a queue
-- refusal lists, so a player can find each one in their Mods folder. Pure.
S.MODS_PER_LINE = 4

function S.mod_id_lines(keys)
	local lines, line = {}, {}
	for _, key in ipairs(keys or {}) do
		line[#line + 1] = tostring(key)
		if #line == S.MODS_PER_LINE then
			lines[#lines + 1] = table.concat(line, ', ')
			line = {}
		end
	end
	if #line > 0 then
		lines[#lines + 1] = table.concat(line, ', ')
	end
	return lines
end

-- A mod key's display name: its SMODS name when installed, else the key.
function S.mod_name(key)
	local mod = SMODS and SMODS.Mods and SMODS.Mods[key]
	return (mod and mod.name) or key
end

function S.mod_names(keys)
	local names = {}
	for i, key in ipairs(keys or {}) do
		names[i] = S.mod_name(key)
	end
	return names
end

-- Where a refusal is shown: a queue press or a rejoin. Each has its own
-- wording (k_queue_refused_<code> / k_rejoin_refused_<code>).
S.RefusalContext = {
	QUEUE = 'queue',
	REJOIN = 'rejoin',
}

-- The sentence saying why, without the mods: "These mods aren't allowed in
-- matchmaking:". refusal: {code, mods} from queue_refusal or rejoin_refusal.
function S.refusal_lead(refusal, context)
	local text = localize('k_' .. context .. '_refused_' .. tostring(refusal.code))
	if text == 'ERROR' then
		return localize('k_' .. context .. '_refused_unknown')
	end
	return text
end

-- The lead with the mods named, on one line.
function S.refusal_text(refusal, context)
	local lead = S.refusal_lead(refusal, context or S.RefusalContext.QUEUE)
	if #refusal.mods == 0 then
		return lead
	end
	return lead .. ' ' .. S.format_mods(S.mod_names(refusal.mods))
end

-----------------------------
-- CACHE
-----------------------------

-- {view, listeners, verdict_waiters}. view stays nil until the server says.
C.standing = C.standing or { view = nil, listeners = {}, verdict_waiters = {} }
local cache = C.standing

local function notify_listeners()
	-- Repaint the main-menu badge, but never over a live run: see
	-- MPAPI.anticheat.mark_server_verified for why account_button is
	-- only safe to rebuild on the main menu.
	if MPAPI.account_button and G.STAGE == G.STAGES.MAIN_MENU then
		MPAPI.account_button:update()
	end
	for _, fn in ipairs(cache.listeners) do
		local ok, err = pcall(fn, cache.view)
		if not ok then
			MPAPI.sendWarnMessage('[standing] listener failed: ' .. tostring(err))
		end
	end
end

-- Takes a StandingView from the server. Returns the view kept, or nil when
-- the data was not one.
function C.remember_standing(data)
	local view = S.view_of(data)
	if view then
		cache.view = view
		notify_listeners()
	end
	return view
end

-- The standing is per session: forget it with the session.
function C.forget_standing()
	cache.view = nil
end

-- A launcher verdict (105) can change the standing: ask the server for the
-- new one, and wake whoever waits for the verdict.
function C.on_launcher_verdict(verified)
	MPAPI.refresh_account_standing()
	local waiters = cache.verdict_waiters
	cache.verdict_waiters = {}
	for _, fn in ipairs(waiters) do
		fn(verified)
	end
end

-- cb(verified) once a launcher verdict lands, or cb(false) after
-- timeout_secs. Straight away when the account is already verified.
function C.await_launcher_verdict(timeout_secs, cb)
	if S.is_verified(cache.view, MPAPI.is_launcher_verified()) then
		cb(true)
		return
	end
	local done = false
	local function finish(verified)
		if not done then
			done = true
			cb(verified)
		end
	end
	table.insert(cache.verdict_waiters, finish)
	local deadline = love.timer.getTime() + timeout_secs
	G.E_MANAGER:add_event(Event({
		blockable = false,
		blocking = false,
		no_delete = true,
		func = function()
			if done then
				return true
			end
			if love.timer.getTime() >= deadline then
				finish(false)
				return true
			end
			return false
		end,
	}))
end

-----------------------------
-- PUBLIC API
-----------------------------

-- The account's StandingView ({standing, disallowed, reason}), or
-- nil before the server has said (or on a server without standings).
function MPAPI.account_standing()
	return cache.view
end

-- ok, refusal: whether this account may queue `kind` (MPAPI.QueueKind) right
-- now. refusal ({code, mods}, code an MPAPI.QueueRefusalCode) says why not;
-- MPAPI.show_standing_refusal(refusal) shows it.
function MPAPI.can_queue(kind)
	local refusal = S.queue_refusal(cache.view, kind, MPAPI.is_launcher_verified())
	return refusal == nil, refusal
end

-- fn(view) after every change to the cached standing, e.g. to repaint queue
-- buttons. Stays for the session.
function MPAPI.on_standing_changed(fn)
	table.insert(cache.listeners, fn)
end

-- Asks the server again. cb(err, view) when given.
function MPAPI.refresh_account_standing(cb)
	cb = cb or function() end
	local conn = C.connection
	if not conn or conn:get_state() ~= MPAPI.ConnectionState.CONNECTED then
		cb(MPAPI.make_error(MPAPI.ErrorKind.NOT_CONNECTED, 'Not connected'), nil)
		return
	end
	conn:_nakama_rpc('account_standing', {}, function(err, data)
		if err then
			cb(MPAPI.make_error(MPAPI.ErrorKind.SERVER, err), nil)
			return
		end
		cb(nil, C.remember_standing(data))
	end)
end

-- The error value a standing refusal is reported as.
function MPAPI.standing_refusal_error(refusal)
	local kind_of = {
		[Refusal.MODS_NOT_ALLOWED] = MPAPI.ErrorKind.MODS_NOT_ALLOWED,
		[Refusal.MODS_UNREPORTED] = MPAPI.ErrorKind.MODS_UNREPORTED,
		[Refusal.INTEGRITY_REQUIRED] = MPAPI.ErrorKind.INTEGRITY_REQUIRED,
	}
	return MPAPI.make_error(kind_of[refusal.code] or MPAPI.ErrorKind.SERVER, S.refusal_text(refusal))
end

do
	local notify = MPAPI.networking.nakama_notify
	if notify then
		notify.on(notify.Code.STANDING_CHANGED, function(content)
			C.remember_standing(content)
		end)
	end
end
