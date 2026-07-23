-- Loader for the api_client package. core.lua loads networking modules by explicit
-- name (no directory scan), so this file stays at the path core.lua expects and pulls
-- in the package parts. client.lua must load first: it creates the table and new(),
-- which every other part extends with endpoint methods.
MPAPI.load_mpapi_file('networking/api_client/client.lua')
MPAPI.load_mpapi_file('networking/api_client/auth.lua')
MPAPI.load_mpapi_file('networking/api_client/account.lua')
MPAPI.load_mpapi_file('networking/api_client/lobby.lua')
MPAPI.load_mpapi_file('networking/api_client/matchmaking.lua')
MPAPI.load_mpapi_file('networking/api_client/replay.lua')
MPAPI.load_mpapi_file('networking/api_client/draft.lua')
