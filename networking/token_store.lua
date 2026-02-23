local token_store = {}

local STORE_PATH = "config/mpapi_auth.jkr"

function token_store.save(token)
    compress_and_save(STORE_PATH, token)
end

function token_store.load()
    local ok, result = pcall(get_compressed, STORE_PATH)
    if ok and result and result ~= "" then
        return result
    end
    return nil
end

function token_store.clear()
    pcall(love.filesystem.remove, STORE_PATH)
end

return token_store
