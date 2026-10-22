# Multiplayer API for Balatro

Multiplayer API (mod id `MultiplayerAPI`, global `MPAPI`) is a [Steamodded](https://github.com/Steamodded/smods) library mod that gives other Balatro mods online multiplayer. It handles the account and server connection, lobbies, matchmaking, actions between players, chat, replays and moderation. The mods built on it only describe their own game rules.

It is part of the Balatro Multiplayer Platform:

| Repository | Mod id | What it is |
|---|---|---|
| [BalatroMultiplayerAPI](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI) | `MultiplayerAPI` | This library |
| [BalatroMultiplayerPvP](https://github.com/Balatro-Multiplayer/BalatroMultiplayerPvP) | `MultiplayerPvP` | Head-to-head PvP gamemodes |
| [BalatroMultiplayerSpeedrunning](https://github.com/Balatro-Multiplayer/BalatroMultiplayerSpeedrunning) | `MultiplayerSPDRN` | Speedrun gamemodes |
| [BalatroMultiplayerServer](https://github.com/Balatro-Multiplayer/BalatroMultiplayerServer) | n/a | The server: Nakama runtime, website and admin tools |

MPAPI on its own adds an account button and the multiplayer menu. You need at least one gamemode mod (PvP or Speedrun) to actually play.

> The older MQTT-based version of the platform is on the [`legacy`](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI/tree/legacy) branch. It is frozen and no longer works against the live server.

## Installing

### Players

The easiest route is the Balatro Multiplayer launcher. It installs the mods for you, and it is required for ranked play. To install by hand:

1. Install [Lovely](https://github.com/ethangreen-dev/lovely-injector) 0.8 or newer and [Steamodded](https://github.com/Steamodded/smods) 1.0.0~BETA-1221a or newer.
2. Put this mod's folder (or its release zip) in your Balatro `Mods` directory:
   - **Windows:** `%AppData%\Balatro\Mods\`
   - **Linux (Proton):** `~/.steam/steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/`
   - **macOS:** `~/Library/Application Support/Balatro/Mods/`
3. Install the gamemode mods you want to play the same way.
4. Launch Balatro **through Steam**. Login uses your Steam session ticket, so the multiplayer menu stays offline without the Steam client.

Keep only one copy of each mod in `Mods/`. Two folders with the same mod id stop either one from loading.

### OpenSSL

MPAPI connects to the server over TLS. It does this by loading OpenSSL through LuaJIT FFI (`networking/openssl_ffi.lua`). The Windows and macOS libraries ship in this mod's `networking/` folder (see `networking/NOTICE-OpenSSL.txt`), so a normal install needs nothing extra. Where MPAPI looks, in order:

| Platform | Files | Where MPAPI looks |
|---|---|---|
| Windows, Linux via Proton | `libssl-3-x64.dll`, `libcrypto-3-x64.dll` (OpenSSL 1.1 names also accepted) | This mod's `networking/` folder, then the default DLL search path, the folder containing `Balatro.exe`, the save directory and the working directory. |
| macOS | `libssl.3.dylib`, `libcrypto.3.dylib` (universal x86_64 + arm64) | This mod's `networking/` folder, then the directory in `BET_OPENSSL_DYLIB_DIR` (set by the launcher). Apple's system `libssl` is LibreSSL and is never loaded. |
| Linux (native) | `libssl.so.3` / `libcrypto.so.3` (or 1.1) | The system OpenSSL from the default library path and the standard lib dirs. Install your distribution's `openssl` package. |

The bundled copy is only loadable when the mod is an extracted folder. A mod left as a zip falls back to the other locations. If OpenSSL can't be found, the game still starts, but MPAPI stays offline. The Lovely log shows every path it tried, with lines prefixed `[OpenSSL]`.

### Mod developers

Clone the repository straight into `Mods/`, or symlink it there. The folder name does not matter.

```sh
git clone https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI.git
```

When `dev/init.lua` is present, the mod loads it. It switches the client to a local server stack (Nakama on `127.0.0.1:7350`, plain HTTP) and turns on a few developer switches, all read from environment variables:

| Variable | Effect |
|---|---|
| `BMP_SERVER_HOST`, `BMP_SERVER_PORT` | Use this server instead of the local stack |
| `BMP_IMPERSONATE_ID` / `BMP_IMPERSONATE_NAME` | Log in as another account with a Nakama device login (the server must allow device auth). This lets you run several game instances on one Steam account. |
| `BMP_DEV_SKIP_RANKED_ANTICHEAT` | Treat the launcher's ranked supervision as present so ranked queues can be tested |

Follow BalatroMultiplayerServer's README to run the server stack locally. Players never get `dev/`: release builds strip it.

## Configuration

`config.lua` is the Steamodded mod config. Players can toggle `chat_enabled` in-game. You can also set the server endpoints there. Each one falls back to the production default when it is unset:

| Key | Default |
|---|---|
| `server_host` | `nakama.balatromp.com` |
| `server_port` | `443` |
| `server_secure` | `true` |
| `nakama_server_key` | `defaultkey` |
| `web_url` | `https://new.balatromp.com` (match-log and report links) |

Options passed to `MPAPI.connect{ host, port, secure, server_key, web_url }` take precedence over the config. On Windows, write `127.0.0.1` rather than `localhost`. Windows tries IPv6 first, and the connection then stalls for about 20 seconds before it falls back to IPv4.

## Using MPAPI from a mod

Declare the dependency in your mod's JSON:

```json
"dependencies": ["Steamodded (>=1.0.0~BETA-1221a)", "Lovely (>=0.8)", "MultiplayerAPI"]
```

The best reference is the gamemode mods. BalatroMultiplayerSpeedrunning's `core.lua` shows a complete registration.

### Startup: `MPAPI.on_loaded`

Do your registration inside `MPAPI.on_loaded(fn)`. MPAPI runs these callbacks once Steam is available and the connection has started. While a callback runs, MPAPI sets `SMODS.current_mod` back to the mod that registered it. That way the action types and gamemodes you create there belong to your mod, which matters for lobby routing (see below).

### Pages and registering your mod

Each screen is an `MPAPI.Page`. The page that is showing replaces the main menu. Register your mod's menu and lobby screens as pages, then register the mod with their keys:

```lua
MPAPI.on_loaded(function()
	MPAPI.Page({
		key = 'mymod_main_menu',     -- used verbatim; no Steamodded prefix is added
		category = 'mod_menu',       -- 'mod_menu' | 'lobby_menu' | 'game_select' | ...
		build = function(self) return MyMod.build_menu() end,
	})
	MPAPI.Page({ key = 'mymod_lobby', category = 'lobby_menu', build = function(self) return MyMod.build_lobby() end })

	MPAPI.register_mod({
		id = 'MyMod',
		name = 'My Mod',
		colour = G.C.BLUE,
		main_menu_ui = 'mymod_main_menu', -- page key (required)
		lobby_ui = 'mymod_lobby',         -- page key
		prevent_pause = true,             -- optional
		options_builder = MyMod.options,  -- optional run-options UI
	})
end)
```

Use `MPAPI.pages.show(key, params)` to switch pages. Pages can also define `on_enter`, `cleanup` (an exit animation) and `dispose` hooks; see `api/page/`.

Hooks into the base game should check `MPAPI.is_active('MyMod')` (or `MPAPI.get_active_mod()`). Otherwise your hook also runs during other mods' games.

### Gamemodes

```lua
MPAPI.GameMode({
	key = 'mymod_duel',
	min_players = 2,                  -- or { public = 2, private = 2, ranked = 2 }
	max_players = 2,
	has_ranked_mode = false,
	start_run = function(self, ...) --[[ start the Balatro run ]] end,
	init = function(self) --[[ per-game instance state ]] end,
})
```

`MPAPI.GameModes[key]` holds the definitions. `lobby:get_gamemode_instance()` returns the instance for the current game. Optional flags: `seed_change_allowed`, `draw_vote_allowed`, `has_duration_cap`.

### Lobbies

```lua
local lobby = MPAPI.create_lobby('MyMod', { max_players = 4 })  -- nil when offline
local lobby = MPAPI.join_lobby('MyMod', 'GWLPR')
local lobby = MPAPI.create_local_lobby('MyMod')                 -- in-process only, for solo/practice
MPAPI.get_current_lobby()

lobby:on('connected', function() ... end)  -- event names are in MPAPI.LobbyEvent
lobby.code, lobby.is_host, lobby.player_id
lobby:get_players()                         -- { { id, displayName, is_away, ... }, ... }
lobby:set_metadata({ gamemode = 'mymod_duel' })  -- host only; the server merges and broadcasts it
lobby:get_metadata()
lobby:set_player_state(tbl)                 -- your own state; the server keeps it for reconnects
lobby:leave()
```

Every online lobby is a server-authoritative Nakama match. The server records who sent each message, enforces that only the host can set metadata, and holds a player's seat for a grace period (120 seconds by default) when they drop. A player who reconnects in time is put back into the same lobby.

The server also referees the ready/start/result flow for every gamemode:

```lua
lobby:set_ready(true)
lobby:start_game({ stake = 1, options = {...} })   -- host; fires 'game_started' { seed, stake, options, players }
lobby:report_result({ ...placements... })          -- every player; the server fires 'game_ended'
lobby:abandon_game()  lobby:restart_game()
```

Useful events: `player_joined`, `player_left`, `player_disconnected`, `player_reconnected`, `host_changed`, `metadata_changed`, `player_ready_changed`, `game_started`, `game_ended`, `server_restarting`, `lobby_closed`, `error`, `disconnected`.

### Actions

Actions are how your mod sends game events between players. Define a type once:

```lua
MyMod.actions.swap_joker = MPAPI.ActionType({
	key = 'mymod_swap_joker',
	parameters = { { key = 'joker', type = 'string', required = true } },  -- types: MPAPI.ActionParamType
	on_receive = function(self, from, params)
		-- return a table to reply, or true to just acknowledge
		return { joker = 'j_blueprint' }
	end,
	on_response = function(self, response, err) end,  -- default reply handler
})
```

Then send instances of it through the lobby:

```lua
lobby:action(MyMod.actions.swap_joker):send(player_id, { joker = 'j_joker' })
lobby:action(MyMod.actions.swap_joker):callback(function(self, response, err) ... end):send(player_id, params)
lobby:action(MyMod.actions.swap_joker):broadcast({ joker = 'j_joker' })
```

Parameters are checked against the schema before anything is sent. A lobby only carries its own mod's action types plus MPAPI's built-in ones. If you send another mod's action into it, the action is dropped with a warning. When the server refuses an action, the callback receives `err.kind == MPAPI.ErrorKind.ACTION_REJECTED`.

### Matchmaking

```lua
local handle = MPAPI.matchmaking.queue({ mod_id = 'MyMod', game_mode = 'mymod_duel', ranked = false })
handle:on('lobby_ready', function(lobby) ... end)   -- events: MPAPI.MatchmakingEvent
handle:on('error', function(err) ... end)
```

To queue for ranked, pass `ranked = true` explicitly. MPAPI does not work out ranked from the gamemode name. Every queue checks the account's standing (which mods are installed), and a ranked queue also needs a launcher-supervised session. If a check fails, the handle fires `error` and the `err.kind` says why. `MPAPI.matchmaking` also provides `get_rating`, `get_leaderboard`, `get_queue_counts` and group queues.

### Other building blocks

| API | Purpose |
|---|---|
| `MPAPI.Layer`, `MPAPI.Ruleset` | Bundles of reworked or banned content, and pool gating for multiplayer runs |
| `MPAPI.Blind` / `MPAPI.Joker` / `MPAPI.Consumable` | Synced Steamodded objects that can message their copies on other clients |
| `MPAPI.BanPick`, `MPAPI.ReadyTracker`, `MPAPI.VoteTracker` | Host-authoritative draft and voting helpers |
| `MPAPI.replay` | Reading stored match logs |
| `MPAPI.register_card_info_provider`, `MPAPI.on_winner_declared`, `MPAPI.register_lobby_reconnect` | Extension points for lobby UI, results and rejoin |
| `MPAPI.Result`, `MPAPI.make_error`, `MPAPI.ErrorKind` | Errors as values: callbacks receive `{ kind, message }` |

Each one has its documentation in the header comment of the file that defines it, under `api/`.

## Repository layout

| Path | Contents |
|---|---|
| `core.lua` | Entry point: load order, the per-frame update, and startup |
| `domain/` | Enums and pure value types (`MPAPI.LobbyEvent`, `MPAPI.ErrorKind`, `MPAPI.Result`, ...) |
| `networking/` | Steam ticket, OpenSSL FFI and the bundled OpenSSL libraries, Nakama transport (`nakama_lobby`, `nakama_notify`) and the I/O worker threads |
| `lib/nakama/` | Vendored [nakama-defold](https://github.com/heroiclabs/nakama-defold) SDK, plus `engine/love.lua`, a LÖVE engine adapter |
| `lib/` | Shared helpers, the thread preloader, and the vendored DebugPlus console (MPL-2.0) |
| `api/` | The public API, one folder per concept (`lobby/`, `action/`, `matchmaking/`, `gamemode/`, `page/`, `layers/`, `ruleset/`, `replay/`, ...) |
| `ui/` | Built-in screens and overlays (lobby, account, moderation notices, ...) |
| `anticheat/` | Ranked-mode supervision channel to the launcher; inactive unless the launcher started a ranked session |
| `lovely/` | Lovely patches to the base game (The Order, pool gating, HUD, ban timing, crash guards) |
| `localization/` | UI strings |
| `compatibility/` | Integrations with other mods (DebugPlus) |
| `dev/` | Developer-only overrides; stripped from release builds |

## License

GPL-3.0; see [LICENSE.md](LICENSE.md). Vendored code keeps its own license: `lib/nakama/` is Apache-2.0 and `lib/debugplus/` is MPL-2.0.
