local token_store = {}

local STORE_PATH = 'config/mpapi_auth.jkr'

-- File format (compressed JSON-like via compress_and_save / get_compressed):
-- {
--   accounts = {
--     ["<steam_id>"] = {
--       auto_login    = true | false,
--       refresh_token = "<token>" | nil
--     }
--   }
-- }

local function load_store()
	local ok, result = pcall(get_compressed, STORE_PATH)
	if not ok or not result or result == '' then
		return { accounts = {} }
	end
	local decode_ok, data = pcall(function()
		if json and json.decode then
			return json.decode(result)
		end
		return require('json').decode(result)
	end)
	if not decode_ok or type(data) ~= 'table' then
		return { accounts = {} }
	end
	if type(data.accounts) ~= 'table' then
		data.accounts = {}
	end
	return data
end

local function save_store(store)
	local encode_ok, encoded = pcall(function()
		if json and json.encode then
			return json.encode(store)
		end
		return require('json').encode(store)
	end)
	if encode_ok and encoded then
		compress_and_save(STORE_PATH, encoded)
	end
end

-- Returns the account entry for a Steam ID, or nil if not found / ToS not accepted.
function token_store.get_account(steam_id)
	if not steam_id then
		return nil
	end
	local store = load_store()
	return store.accounts[steam_id]
end

-- Creates a local account entry for a Steam ID after first-time server authentication.
-- Sets auto_login = true and optionally saves a refresh token.
function token_store.create_account(steam_id, refresh_token)
	if not steam_id then
		return
	end
	local store = load_store()
	store.accounts[steam_id] = {
		auto_login = true,
		refresh_token = refresh_token or nil,
	}
	save_store(store)
end

-- Updates the refresh token for an existing account entry.
function token_store.save_refresh_token(steam_id, refresh_token)
	if not steam_id then
		return
	end
	local store = load_store()
	local account = store.accounts[steam_id]
	if not account then
		return
	end
	account.refresh_token = refresh_token
	save_store(store)
end

-- Turns auto-login on or off for a Steam account.
function token_store.set_auto_login(steam_id, enabled)
	if not steam_id then
		return
	end
	local store = load_store()
	local account = store.accounts[steam_id]
	if not account then
		return
	end
	account.auto_login = enabled
	save_store(store)
end

-- Removes the account entry entirely (e.g. on explicit logout / account deletion).
function token_store.clear_account(steam_id)
	if not steam_id then
		return
	end
	local store = load_store()
	store.accounts[steam_id] = nil
	save_store(store)
end

MPAPI.networking.token_store = token_store
