-- Contract test for lib/join_keys.lua and the join that carries the keys.
local T = dofile('tests/support.lua')
local check = T.check

-- The keys a mod adds to its lobby join are text only, never replace the API's own, and a mod
-- that adds none changes nothing.
T.part(function()
	local warnings = {}
	MPAPI = { sendWarnMessage = function(text) warnings[#warnings + 1] = text end }
	dofile('lib/join_keys.lua')
	local keys = MPAPI.join_keys

	local base = { modId = 'M', displayName = 'Jimbo' }

	-- A mod that adds nothing gets the very same table back.
	check(keys.with_mod_keys('Nobody', base) == base, 'no keys added: the same table')

	local function with(extra)
		MPAPI.add_join_keys('Probe', function() return extra end)
		warnings = {}
		return keys.with_mod_keys('Probe', base)
	end

	local result = with({ run = 'abc', last_done = '4' })
	check(result.run == 'abc' and result.last_done == '4' and result.modId == 'M', 'text keys are added')
	check(#warnings == 0, 'nothing left out')
	check(base.run == nil, 'the base table is not changed')

	result = with({ count = 4, flag = true, nested = {}, fine = 'yes' })
	check(result.fine == 'yes' and result.count == nil and result.flag == nil and result.nested == nil, 'only text values are kept')
	check(#warnings == 1 and warnings[1]:find('count, flag, nested', 1, true), 'the left out keys are named in order')

	result = with({ displayName = 'Other', mods = 'x', preferredJoker = 'j', modId = 'N', role = 'spectator' })
	check(result.displayName == 'Jimbo' and result.modId == 'M' and result.mods == nil and result.preferredJoker == nil, 'the API keys stand')
	check(result.role == nil, 'a mod cannot turn the join into a spectate')
	check(#warnings == 1 and warnings[1]:find('displayName, modId, mods, preferredJoker, role', 1, true), 'every attempt on an API key is named')

	-- add_join_keys: asked at every join, so the values are current.
	local join_count = 1
	MPAPI.add_join_keys('Mod', function() return { run = 'r' .. join_count } end)
	check(keys.with_mod_keys('Mod', base).run == 'r1', 'the mod keys are added')
	join_count = 2
	check(keys.with_mod_keys('Mod', base).run == 'r2', 'asked again at the next join')
	check(keys.with_mod_keys('Other', base) == base, 'another mod is not touched')
	MPAPI.add_join_keys('Mod', function() return { run = 'second' } end)
	check(keys.with_mod_keys('Mod', base).run == 'second', 'a second call replaces the first')

	-- The save a crash join is about to load goes to the mod; any other join gives nil.
	local seen = {}
	MPAPI.add_join_keys('Saver', function(save_to_load)
		seen[#seen + 1] = save_to_load or 'nil'
		return { run = save_to_load and save_to_load.run or 'none' }
	end)
	local save = { run = 'from the save' }
	check(keys.with_mod_keys('Saver', base, save).run == 'from the save' and seen[1] == save, 'the mod gets the save about to be loaded')
	check(keys.with_mod_keys('Saver', base).run == 'none' and seen[2] == 'nil', 'a join with no save gives the mod nil')

	-- A mod that breaks must not stop the join.
	warnings = {}
	MPAPI.add_join_keys('Broken', function() error('boom') end)
	check(keys.with_mod_keys('Broken', base) == base, 'a failing mod adds nothing')
	check(#warnings == 1, 'and says so once')
	MPAPI.add_join_keys('Odd', function() return 'text' end)
	check(keys.with_mod_keys('Odd', base) == base, 'a non-table answer adds nothing')
	warnings = {}
	keys.with_mod_keys('Mod', base)
	check(#warnings == 0, 'a good answer is silent')
	MPAPI.add_join_keys('Mixed', function() return { good = 'a', bad = 1 } end)
	result = keys.with_mod_keys('Mixed', base)
	check(result.good == 'a' and result.bad == nil and #warnings == 1, 'a refused key is warned about, the rest kept')
end)

-- The mod's join keys travel in the metadata of the join the socket sends, the save a crash
-- rejoin will load reaches the mod on that first join only, and a socket-drop rejoin asks the
-- mod again.
T.part(function()
	local now = 0
	love = { timer = { getTime = function() return now end } }
	local sockets = {}
	local joins = {}
	local function new_socket()
		local s = { handlers = {} }
		for _, name in ipairs({ 'on_match_data', 'on_matchmaker_matched', 'on_party', 'on_party_presence_event', 'on_party_leader', 'on_notifications', 'on_error' }) do
			s[name] = function() end
		end
		s.on_disconnect = function(fn) s.handlers.disconnect = fn end
		s.connect = function(cb) cb(true) end
		s.match_join = function(match_id, _, metadata, cb)
			joins[#joins + 1] = { match_id = match_id, metadata = metadata }
			cb({})
		end
		sockets[#sockets + 1] = s
		return s
	end

	local connection = {
		player_id = 'me',
		display_name = 'Jimbo',
		with_session = function(_, cb) cb({}) end,
		nakama_client = { create_socket = new_socket },
	}
	MPAPI = {
		networking = {},
		get_connection = function() return connection end,
		collect_installed_mods = function() return {} end,
		json_encode = function() return '{}' end,
		sendWarnMessage = function() end,
	}
	dofile('lib/join_keys.lua')
	dofile('networking/nakama_lobby.lua')
	local NL = MPAPI.networking.nakama_lobby

	local asked = {}
	local join_count = 0
	MPAPI.add_join_keys('pvp', function(save_to_load)
		join_count = join_count + 1
		asked[#asked + 1] = save_to_load or 'nil'
		return { pvp_run = 'run' .. join_count, role = 'spectator' }
	end)

	-- The first join carries the mod's key, with the save the rejoin will load; the API's own keys stand.
	local save = { name = 'the save' }
	local joined_error = 'not called'
	NL.join('match1', 'pvp', { data = function() end }, function(err) joined_error = err end, save)
	check(joined_error == nil, 'the join went through')
	check(#joins == 1 and joins[1].metadata.pvp_run == 'run1', 'the mod key is in the metadata that was sent')
	check(joins[1].metadata.modId == 'pvp' and joins[1].metadata.role == nil, 'the API keys stand')
	check(asked[1] == save, 'the mod was given the save to load on the first join')

	-- A socket-drop rejoin asks again, with no save.
	sockets[1].handlers.disconnect()
	now = 10
	NL.update()
	check(#joins == 2 and joins[2].metadata.pvp_run == 'run2', 'the rejoin asks the mod again')
	check(asked[2] == 'nil', 'the rejoin gives the mod no save')

	-- A mod that adds nothing: the join is what it always was.
	joins = {}
	asked = {}
	NL.forget()
	NL.join('match2', 'speedrun', { data = function() end }, function() end)
	check(#joins == 1 and joins[1].metadata.pvp_run == nil and #asked == 0, 'a mod with no join keys sends none and is not asked')
end)

T.done('join_keys_test')
