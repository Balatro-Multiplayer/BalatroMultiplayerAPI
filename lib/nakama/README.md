# Vendored Nakama Lua SDK

Source: [heroiclabs/nakama-defold](https://github.com/heroiclabs/nakama-defold),
`master` @ `dc42c3ff47a8447cda9d2320fbc12ad6e1ec441e` (2026-09-17), Apache-2.0
(see `LICENSE`).

## Vendored unmodified

- `nakama.lua`, `session.lua`, `socket.lua`
- `util/` (`async`, `b64`, `json`, `log`, `retries`, `time`, `uri`, `uuid`)

Module names match upstream's (`nakama.nakama`, `nakama.util.json`, ...), so
`thread_preload.build_preload_table('lib/nakama', 'nakama')` produces the names
the SDK's own `require` calls look up.

## Not vendored

- `nakama/engine/defold.lua` and `nakama/engine/test.lua`: the Defold and
  test engines. `engine/love.lua` replaces the Defold one.
- `satori/`, `test/`, `example/`, `codegen/`, `docs/`

## MPAPI additions

- `engine/love.lua`: the LÖVE engine (`uuid`, `http`, `socket_create`,
  `socket_connect`, `socket_disconnect`, `socket_send`, plus `update` and
  `shutdown`). It follows `engine/defold.lua`'s callback contract, including
  retry and cancellation handling.
- `networking/nakama_http_thread.lua`, `networking/nakama_ws_thread.lua`: I/O
  threads.
- `networking/nakama_net.lua`: TCP/TLS streams (TLS through `openssl_ffi`) and
  an HTTP/1.1 client.
- `networking/websocket.lua`: an RFC 6455 client.
- `networking/nakama_sdk.lua`: the loader.

`session.store`/`session.restore` use Defold's `sys` module and don't work
here. Don't call them.

Only used for login so far: with the config option `use_nakama_auth` on (and
`use_custom_server`), `api/connection/lifecycle.lua` loads the SDK and
`networking/connection.lua`'s `_try_nakama_auth` signs in to Nakama with the
Steam ticket. With it off, nothing loads the SDK.

## Updating

Copy the files listed above from a newer upstream commit, update the commit
here, and compare `nakama/engine/defold.lua` against the previous commit for
engine-contract changes that `engine/love.lua` needs to follow.
