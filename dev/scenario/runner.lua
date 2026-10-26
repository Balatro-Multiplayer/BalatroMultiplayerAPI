-- Opt-in scenarios run against the live game, one step per update.
local selector = os.getenv('BMP_SCENARIO')
local mod_id, name = selector:match('^([%w_%-]+):([%w_%-]+)$')
local S = { pass = 0, fail = 0 }
local started, finished = false, false
local steps, index, elapsed = nil, 1, 0

local function emit(message)
	sendInfoMessage('BMP_SCENARIO ' .. message, 'MPAPI')
end

emit('START ' .. selector .. ' run=' .. (os.getenv('BMP_SCENARIO_RUN_ID') or 'manual'))

function S.check(condition, message)
	local result = condition and 'PASS' or 'FAIL'
	if condition then
		S.pass = S.pass + 1
	else
		S.fail = S.fail + 1
	end
	emit(result .. ' ' .. tostring(message):gsub('[\r\n]', ' '))
	return condition
end

local function finish()
	finished = true
	if S.pass + S.fail == 0 then
		S.check(false, 'scenario made no assertions')
	end
	emit(('DONE pass=%d fail=%d'):format(S.pass, S.fail))
	if os.getenv('BMP_SCENARIO_QUIT') == '1' then
		love.event.quit()
	end
end

local function fail(message)
	S.check(false, message)
	finish()
end

local function load_scenario()
	if not mod_id or not SMODS.Mods[mod_id] then
		return nil, 'expected an installed mod and scenario: <mod_id>:<name>'
	end
	local chunk, err = SMODS.load_file('tests/scenarios/' .. name .. '.lua', mod_id)
	if not chunk then
		return nil, err
	end
	local result = chunk()
	assert(type(result) == 'table' and #result > 0, 'scenario must return a nonempty step list')
	for i, step in ipairs(result) do
		assert(type(step) == 'table', 'invalid step ' .. i)
		assert(step.run == nil or type(step.run) == 'function', 'invalid run in step ' .. i)
		assert(step.until_ == nil or type(step.until_) == 'function', 'invalid predicate in step ' .. i)
		assert(step.wait == nil or (type(step.wait) == 'number' and step.wait >= 0), 'invalid wait in step ' .. i)
		assert(step.timeout == nil or (type(step.timeout) == 'number' and step.timeout > 0), 'invalid timeout in step ' .. i)
	end
	return result
end

-- The splash otherwise waits for input. Restore the setting before it can be saved.
local splash_ref = Game.splash_screen
function Game:splash_screen()
	local skip = G.SETTINGS.skip_splash
	G.SETTINGS.skip_splash = 'Yes'
	local ok, err = pcall(splash_ref, self)
	G.SETTINGS.skip_splash = skip
	if not ok then
		fail('splash: ' .. tostring(err))
	end
end

local update_ref = Game.update
function Game:update(dt)
	update_ref(self, dt)
	if finished then
		return
	end
	if not started then
		elapsed = elapsed + dt
		if elapsed >= 20 then
			return fail('startup timed out waiting for the main menu')
		end
		if G.STATE ~= G.STATES.MENU or not G.MAIN_MENU_UI then
			return
		end
		started = true
		elapsed = 0
		local ok, result, err = pcall(load_scenario)
		if not ok or not result then
			return fail('load: ' .. tostring(ok and err or result))
		end
		steps = result
		return
	end

	local step = steps[index]
	if not step then
		return finish()
	end
	elapsed = elapsed + dt
	local wait = step.wait or 0.5
	if elapsed < wait then
		return
	end
	if step.until_ then
		local ok, satisfied = pcall(step.until_)
		if not ok then
			return fail('step ' .. index .. ' predicate: ' .. tostring(satisfied))
		end
		if not satisfied then
			if elapsed >= wait + (step.timeout or 10) then
				fail('step ' .. index .. ' timed out')
			end
			return
		end
	end
	if step.run then
		local ok, err = pcall(step.run, S)
		if not ok then
			return fail('step ' .. index .. ': ' .. tostring(err))
		end
	end
	index, elapsed = index + 1, 0
end
