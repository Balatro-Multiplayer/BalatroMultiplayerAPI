# AGENTS.md

MultiplayerAPI (`MPAPI`): a Steamodded/Lovely library mod. It gives Balatro gamemode mods (PvP, SPDRN) a Nakama-backed multiplayer layer. Read README.md for the public API and folder map. This file only covers what the code does not make obvious.

## Where things live

- The load order is in `core.lua`, and the order matters: `domain/` → `networking/` → `anticheat/` → `lib/` (top level only) → the ordered preloads → `api/` (recursive) → `ui/` → `dev/init.lua`. The directory scan order is **not** guaranteed. A file that needs another file at load time has to be preloaded explicitly in `core.lua`; existing examples are `api/replay/codes.lua` and `api/page/definition.lua`.
- `MPAPI.load_mpapi_file` loads each path at most once and returns that file's cached result. Use it to pull in a sibling module (`local x = MPAPI.load_mpapi_file('lib/foo.lua')`).
- State shared between files goes on `MPAPI._internal.<area>` and is initialised with `X = X or {}`. That keeps load order from mattering. Public API goes on `MPAPI.*`.
- Wire contracts are mirrored by hand in BalatroMultiplayerServer's `nakama/` module. Change both sides together:
  - lobby op codes: `networking/nakama_lobby.lua` ↔ `nakama/src/lobby/protocol.ts`
  - notification codes: `networking/nakama_notify.lua` ↔ `nakama/src/notify.ts`
  - authoritative actions: `api/action/builtin.lua` ↔ `nakama/src/actions/registry.ts`
- `lib/nakama/` is vendored upstream nakama-defold; its README is upstream's. The only file of ours in it is `lib/nakama/engine/love.lua`. Make fixes there or in `networking/`, not in the SDK files.
- `lib/debugplus/` is vendored (MPL-2.0); leave it as upstream wrote it.

## Coding style

1. **Code describes itself.** Names carry the meaning. Write a comment only for a *why* the code cannot express (a race, a vanilla quirk, a server contract). File headers explain the module's role.
2. **Structure is the namespace.** The folder and file path is the documentation (`api/lobby/reconnect.lua`, `api/matchmaking/group/queue.lua`). New concepts get a new file in the right folder rather than growing an existing one.
3. **Single responsibility.** One file has one job. Transport (`networking/`) does not know lobby semantics (`api/lobby/`), and neither of them builds UI (`ui/`).
4. **Dependency inversion.** Infrastructure sits behind small contracts that are wired at a composition root. Examples: the Nakama engine adapter, `connection.new(opts)` receiving its client, and dev overrides replacing `connection._do_auth`. Domain code calls the contract, never a concrete socket.
5. **Errors are values at I/O boundaries.** Callbacks are `cb(err, data)`, where `err` comes from `MPAPI.make_error(MPAPI.ErrorKind.X, msg)` (`domain/result.lua`). `error()`/`assert` are only for programmer bugs, such as a bad registration or a load failure.
6. **No stringly-typed domain concepts.** Use the enums in `domain/` (`MPAPI.LobbyEvent`, `MPAPI.ErrorKind`, `MPAPI.LobbyType`, ...). To add a value, add it to the enum. Their string values are wire strings that external mods also pass, so keep them stable.
7. **Pure separate from effectful.** Validation, rules and serialisation are pure functions (`api/action/validation.lua`, `MPAPI.standing`, the websocket framing). Effects stay in thin outer layers.

Formatting: run `stylua` with the repo's `stylua.toml` (tabs, single quotes). User-facing text goes through `localize()` keys in `localization/en-us.lua`.

## Gotchas

- **Never `require()` the mod's own files.** BET deploys mods as zips that Steamodded mounts virtually. `require()` can't read inside a mount, and dotted module names get mangled into backslash paths. On the main thread, use `MPAPI.load_mpapi_file`.
- **Worker threads are separate Lua states.** `networking/nakama_*_thread.lua` and `anticheat/launcher_thread.lua` have no `MPAPI`, no `G`, no `SMODS` and no hooked `love.filesystem`. They get `package.path` plus pre-read module sources through their channel (`lib/thread_preload.lua`) and then `require` from `package.preload`. A module used inside a thread (`openssl_ffi`, `nakama_net`, `websocket`) has to work with `MPAPI == nil`. Channel messages must be flat tables. Environment variables are process-wide, so threads can read them.
- **Nothing networked happens without `MPAPI.update()`.** A non-blocking, `no_delete` event calls it every frame. It pumps `engine.update()` and `nakama_lobby.update()`, and that is the only place SDK callbacks fire. Code that needs a per-frame tick chain-wraps `MPAPI.update` (save the old reference, call it); do not replace it.
- **`MPAPI.on_loaded` waits for `G.STEAM`.** Without the real Steam client, registration callbacks never run and gamemode mods appear to silently do nothing.
- **`on_loaded` restores `SMODS.current_mod`.** Action types and gamemodes are tagged with the creating mod, and `lobby._action_types` filters by that tag. Create them at file load time or inside `on_loaded`, never from a later deferred event.
- **Page keys are not prefixed** (`prefix_config = { key = false }`). `register_mod` and `MPAPI.pages.show` use them verbatim.
- **Authoritative actions are MPAPI-only.** A mod's `authoritative = true` is downgraded to a relayed action. The server only referees `mpapi_*` actions.
- **An empty Lua table encodes as a JSON `[]`**, not `{}`. When the server expects an object, guard for it (see `networking/nakama_lobby.lua`).
- **Windows `localhost` resolves to IPv6 first** and stalls about 20 seconds against a WSL2 server. Use `127.0.0.1`.
- **TLS does not verify certificates** (`verify = false` in `networking/nakama_net.lua`). Keep that in mind before relying on transport security for anything new.
- **OpenSSL is bundled in `networking/`** for Windows/Proton and macOS, and FFI loads it from there first (found via `package.path`, because threads have no `MPAPI`). Fallbacks are next to `Balatro.exe` (Windows) or `BET_OPENSSL_DYLIB_DIR` (macOS). Linux uses the system OpenSSL. libcrypto must load before libssl, since libssl resolves it by name (Windows) or `@loader_path` (macOS). If it is missing, the client stays offline. Never load OpenSSL by bare name on macOS: that picks up the system LibreSSL and aborts the process.
- **`dev/` is stripped from `main`** by `.github/workflows/strip-dev.yml` on every push. Anything there must be optional: `core.lua` checks for `dev/init.lua` before loading it. Pushes to `main` are what players receive, so `main` must always be releasable.
- **Lovely patches** in `lovely/` target vanilla source text. If a patch stops matching after a Balatro or Steamodded update, it fails silently. Check the Lovely log.

## Verifying changes

There is no offline test runner in this repository. Changes are verified against live game instances:

1. Copy or symlink the mod into Balatro's `Mods/` (one copy per mod id), together with the gamemode mods you are touching.
2. For server work, run the BalatroMultiplayerServer stack locally. `dev/init.lua` points the client at `127.0.0.1:7350`. Use `BMP_IMPERSONATE_*` to give a second instance a different account.
3. Launch through Steam. Check the Lovely log for `MPAPI: failed to ...` load errors, `[OpenSSL]` lines and handler warnings.
4. Drive the real UI flows (create/join, ready, start, report, leave, reconnect) in two or more instances. The project's private test harness, a game-control mod plus CLI, scripts this and runs the suites. Prefer exercising the real UI path over calling internals directly.
5. If you changed a wire contract, run the matching server-side change at the same time.
