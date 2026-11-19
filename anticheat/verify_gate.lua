--[[
    State machine for the startup "verifying Ranked status" gate.

    On an official-server Ranked launch through BET, the game holds at the
    main menu until the launcher<->mod<->server chain has finished (the
    server's login challenge answered by the launcher and accepted). Load
    time on a slow machine says nothing about whether the Run is legitimate,
    so nothing here ends the game: each attempt gets `window` seconds, and if
    it doesn't finish in time the player chooses to keep waiting (a fresh
    attempt with a fresh window) or give up on Ranked.

        idle -> verifying -> verified
                   |  ^
                   v  |  keep_waiting()
                prompting -> bypassed

    `verified` and `bypassed` are terminal. In particular a bypass can never
    be undone, and a verdict arriving after it is rejected: giving up means
    no Ranked for the rest of the Run, even if the chain completes in the
    background. The launcher enforces the same thing from its side (it
    refuses to sign anything once told), this just keeps the mod's own state
    honest.

    No game, UI or network code in here, so it runs under plain luajit (see
    tests/verify_gate_test.lua). `hooks` are called synchronously:
      on_verifying(attempt)  a (re)started attempt - show the waiting overlay
      on_prompt()            the window ran out - ask keep waiting / give up
      on_attempt(attempt)    a fresh attempt began - kick off a new challenge
      on_done(state)         terminal: 'verified' or 'bypassed' - clear the UI
      on_bypass()            the player gave up - tell the launcher
]]

local Gate = {}
Gate.__index = Gate

Gate.State = {
	IDLE = 'idle',
	VERIFYING = 'verifying',
	PROMPTING = 'prompting',
	VERIFIED = 'verified',
	BYPASSED = 'bypassed',
}
local S = Gate.State

-- Seconds a single attempt waits before the player is asked what to do.
Gate.DEFAULT_WINDOW = 5

function Gate.new(opts)
	opts = opts or {}
	return setmetatable({
		window = opts.window or Gate.DEFAULT_WINDOW,
		now = opts.now,
		hooks = opts.hooks or {},
		state = S.IDLE,
		attempts = 0,
		deadline = nil,
	}, Gate)
end

local function fire(self, name, ...)
	local hook = self.hooks[name]
	if hook then
		hook(...)
	end
end

function Gate:_begin_attempt()
	self.attempts = self.attempts + 1
	self.state = S.VERIFYING
	self.deadline = self.now() + self.window
end

-- Begins the first attempt. A no-op once anything has happened already, so
-- a verdict that beat the main menu to it isn't undone.
function Gate:start()
	if self.state ~= S.IDLE then
		return
	end
	self:_begin_attempt()
	fire(self, 'on_verifying', self.attempts)
end

-- Call every frame while blocking.
function Gate:tick()
	if self.state == S.VERIFYING and self.now() >= self.deadline then
		self.state = S.PROMPTING
		fire(self, 'on_prompt')
	end
end

-- The server accepted the launcher's answer. Returns whether it counted.
function Gate:verified()
	if self.state == S.BYPASSED or self.state == S.VERIFIED then
		return self.state == S.VERIFIED
	end
	local was_blocking = self:is_blocking()
	self.state = S.VERIFIED
	if was_blocking then
		fire(self, 'on_done', S.VERIFIED)
	end
	return true
end

-- "Keep waiting": a fresh attempt with a fresh window.
function Gate:keep_waiting()
	if self.state ~= S.PROMPTING then
		return
	end
	self:_begin_attempt()
	fire(self, 'on_attempt', self.attempts)
	fire(self, 'on_verifying', self.attempts)
end

-- "Give up": Ranked is off for the rest of this Run.
function Gate:bypass()
	if self.state ~= S.VERIFYING and self.state ~= S.PROMPTING then
		return
	end
	self.state = S.BYPASSED
	fire(self, 'on_bypass')
	fire(self, 'on_done', S.BYPASSED)
end

function Gate:is_blocking()
	return self.state == S.VERIFYING or self.state == S.PROMPTING
end

function Gate:is_bypassed()
	return self.state == S.BYPASSED
end

return Gate
