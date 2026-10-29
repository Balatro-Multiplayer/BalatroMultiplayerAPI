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

## Installation

### Launchers

Launchers are the easiest ways to get modded Balatro running quickly. We have two main launchers we support:

#### R2 Mod Man

We recommend downloading the mod with r2mm if you intend to play it casually. You can download r2mm here: [https://r2modman.com/](https://r2modman.com/)

#### BET

Otherwise you can use own custom closed source launcher called BET, which is intended to be a successor of BMM. You can download BET here: [https://new.balatromp.com/download](https://new.balatromp.com/download)

### Manual

Requirements:

- [Steamodded](https://github.com/Steamodded/smods) (>= 1.0.0~BETA-1814a)
- [Lovely Injector](https://github.com/ethangreen-dev/lovely-injector) (>= 0.10)
- Balatro running through Steam (the API signs in with your Steam account)

Steps:

1. Install Steamodded and Lovely.
2. Download the latest release of this mod from the [Releases page](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI/releases).
3. Extract it into its own folder in your Balatro `Mods` directory. Make sure the folder is not nested inside a second folder of the same name.
4. Install at least one gamemode mod ([PvP](https://github.com/Balatro-Multiplayer/BalatroMultiplayerPvP) or [Speedrunning](https://github.com/Balatro-Multiplayer/BalatroMultiplayerSpeedrunning)) the same way.
5. Launch the game through Steam.

## Configuration

### Join a Community server

By default the game plays on the Official server. To play on a Community server, get its address from the person who runs it. Then:

1. Close Balatro.
2. Open `config.lua` in MPAPI's folder in `Mods`, and add the server keys inside the braces:

   ```lua
   return {
   	['chat_enabled'] = false,
   	['use_custom_server'] = true,
   	['server_host'] = '127.0.0.1', -- the server's address
   	['server_port'] = 7350,
   	['server_secure'] = false,
   }
   ```

3. If `config/MultiplayerAPI.jkr` exists in the Balatro save folder, delete it (it can hold older settings).
4. Start Balatro through Steam. The game logs in with Device login, so it still needs the Steam client for your Steam id. The Lovely log shows `Login: Device (server is not Official)`.

On a Community server your account and rating are separate from the Official server. Ranked does not need the launcher there, and you may queue with any mods. Player names on a Community server are not proven: anyone can use any name.

Each key falls back to the Official server's value when it is unset. The game reads the `server_*` keys only when `use_custom_server = true`:

| Key | Official server value |
|---|---|
| `server_host` | `nakama.balatromp.com` |
| `server_port` | `443` |
| `server_secure` | `true` (TLS) |
| `nakama_server_key` | `defaultkey` |
| `web_url` | `https://new.balatromp.com` (match-log and report links) |

On Windows, write `127.0.0.1` rather than `localhost`. Windows tries IPv6 first, and the connection then stalls for about 20 seconds before it falls back to IPv4.

To go back to the Official server, remove the `use_custom_server` line from `config.lua`, delete `config/MultiplayerAPI.jkr` again, and restart Balatro. You can leave the `server_*` keys: the game ignores them. A new MPAPI version replaces `config.lua`, so you then add the keys again.

To run a Community server yourself, see "Run a Community server" in the [BalatroMultiplayerServer README](https://github.com/Balatro-Multiplayer/BalatroMultiplayerServer#run-a-community-server).

### Mod code

Options passed to `MPAPI.connect{ host, port, secure, server_key, web_url }` take precedence over the config.

## Using MPAPI from a mod

Declare the dependency in your mod's JSON:

```json
"dependencies": ["Steamodded (>=1.0.0~BETA-1814a)", "Lovely (>=0.10)", "MultiplayerAPI"]
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
lobby:set_result_pending(true)                     -- any player; the server holds the run open until you pass false
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
| `MPAPI.Setup`, `MPAPI.BanPick` | Server-run Setup (Draft and votes) before a run, and the deck Draft screen |
| `MPAPI.ReadyTracker`, `MPAPI.VoteTracker` | Host-authoritative ready and voting helpers |
| `MPAPI.replay` | Reading stored match logs |
| `MPAPI.register_card_info_provider`, `MPAPI.on_winner_declared`, `MPAPI.register_lobby_reconnect` | Extension points for lobby UI, results and rejoin |
| `MPAPI.Result`, `MPAPI.make_error`, `MPAPI.ErrorKind` | Errors as values: callbacks receive `{ kind, message }` |

Each one has its documentation in the header comment of the file that defines it, under `api/`.

## AI Content Disclaimer

This library does NOT use AI for art or other assets. It uses generative AI in its development as a tool for writing code.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Changes to the public API affect every mod built on it, so open an issue or ask on [Discord](https://discord.gg/balatromp) first. Changes to the wire contract with the server also need a matching change in [BalatroMultiplayerServer](https://github.com/Balatro-Multiplayer/BalatroMultiplayerServer). Bug fixes and quality-of-life work are always welcome. Check the [issues](https://github.com/Balatro-Multiplayer/BalatroMultiplayerAPI/issues), especially those tagged "Help Wanted".

## License

GPL-3.0; see [LICENSE.md](LICENSE.md). Vendored code keeps its own license: `lib/nakama/` is Apache-2.0 and `lib/debugplus/` is MPL-2.0.
