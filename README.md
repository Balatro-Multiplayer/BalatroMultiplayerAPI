# MultiplayerAPI for Balatro

A mod library that adds real-time multiplayer to [Balatro](https://www.playbalatro.com/). Provides lobby management, player state sync, actions, chat, and player authentication with Steam and Discord.

## API

All functions are accessed through the global `MPAPI` table.

`create_lobby` and `join_lobby` are async: they create or find the lobby match on the server, then join it. Use the `on("connected")` event to know when the lobby is ready.

By default, lobbies connect to the official MultiplayerAPI server. Self-hosted servers can be configured via the mod config (see [Configuration](#configuration)).

### Lobby

```lua
-- Create a new lobby for your mod. Returns a lobby object.
-- Generates a short join code, authenticates with the server,
-- and joins it.
local lobby = MPAPI.create_lobby("my_mod_id")

-- Join an existing lobby by code.
local lobby = MPAPI.join_lobby("my_mod_id", "GWLPR")

-- Leave the current lobby. Cleans up connections.
lobby:leave()

-- Lobby info
lobby.code        -- "GWLPR"
lobby.mod_id      -- "my_mod_id"
lobby.is_host     -- true/false
lobby.player_id   -- this player's ID
```

### Lobby Metadata

Host-controlled data that describes the lobby. Persists for the lifetime of the lobby and new joiners receive it immediately. Only the host can set metadata (enforced server-side).

```lua
-- Host sets metadata (table, merged with existing)
lobby:set_metadata({ max_players = 4, ante = 1, stake = "gold", deck = "black" })

-- Any player reads metadata
local meta = lobby:get_metadata()
-- { host = "player_123", max_players = 4, ante = 1, difficulty = "gold" }
```

### Player State

Each player publishes their own state. Player state is **private** — players can only read and write their own state (enforced server-side). Any information another player needs should be communicated via [Actions](#actions).

```lua
-- Set your own state (table, replaces previous)
lobby:set_player_state({ score = 1250, hands_left = 3, location = "selecting_blind" })

-- Read your own last known state (e.g. after reconnect)
local state = lobby:get_player_state(self.player_id)

-- Get all players in the lobby
local players = lobby:get_players()
-- { { id = "player_123" }, { id = "player_456" } }
```

### Actions

Actions are the core way mods communicate game-specific events. You define an **action type** with a parameter schema and receive handler, then create **action instances** to send them. Actions support request/response, the receiver can return data that the sender gets via a callback.

#### Defining an Action Type

```lua
my_mod.actions.swap_joker = MPAPI.ActionType({
    -- Unique key for this action
    key = "swap_joker",

    -- Parameters the sender must include (validated before sending)
    parameters = {
        { key = "joker", type = "string", required = true },
    },

    -- Parameters expected in the response (if the receiver responds)
    response_parameters = {
        { key = "joker", type = "string" },
    },

    -- Called when this action is received from another player.
    -- Return a table to send a response, or true to just acknowledge.
    on_receive = function(self, from, params)
        -- from: player ID who sent this
        -- params: { joker = "j_blueprint" }
        -- params are guaranteed to match the schema above

        local my_joker = get_random_joker()
        add_joker_to_hand(params.joker)

        if my_joker then
            remove_joker(my_joker)
            return { joker = my_joker.key }  -- send response back to sender
        else
            return true  -- acknowledge receipt, no response data
        end
    end,

    -- Default callback for when the sender gets a response.
    -- Used unless overridden on a specific action instance.
    on_response = function(self, response)
        if response and response.joker then
            add_joker_to_hand(response.joker)
        end
        remove_joker_by_key(self.params.joker)
    end,
})
```

#### Sending an Action

```lua
-- Uses the default on_response callback defined on the action type
lobby:action(my_mod.actions.swap_joker):send(target_player_id, { joker = "j_blueprint" })

-- Override the callback for a specific instance
local action = lobby:action(my_mod.actions.swap_joker)
action:callback(function(self, response)
    -- This runs instead of on_response for this instance only
    sendDebugMessage("Got response: " .. tostring(response and response.joker))
end)
action:send(target_player_id, { joker = "j_blueprint" })

-- Broadcast to all players in the lobby
lobby:action(my_mod.actions.swap_joker):broadcast({ joker = "j_blueprint" })
```

#### Simple Actions (No Response Needed)

Not every action needs request/response. For fire-and-forget events, skip `response_parameters` and `on_response`:

```lua
my_mod.actions.ready_blind = MPAPI.ActionType({
    key = "ready_blind",
    parameters = {
        { key = "blind", type = "string", required = true },
    },
    on_receive = function(self, from, params)
        mark_player_ready(from, params.blind)
        return true
    end,
})

-- Send it
lobby:action(my_mod.actions.ready_blind):send(host_id, { blind = "bl_small" })
```

### Events

Lifecycle events for the lobby.

```lua
lobby:on("connected", function()
    -- Lobby is ready. Safe to set metadata, subscribe, etc.
end)

lobby:on("player_joined", function(player_id)
    -- A new player connected to the lobby
end)

lobby:on("player_left", function(player_id)
    -- A player disconnected or was removed after grace period expired
end)

lobby:on("player_disconnected", function(player_id)
    -- A player's connection dropped unexpectedly (crash, internet, etc.)
    -- They have 2 minutes to reconnect before being removed
end)

lobby:on("player_reconnected", function(player_id)
    -- A disconnected player came back within the grace period
end)

lobby:on("metadata_changed", function(metadata)
    -- Host updated lobby metadata
end)

lobby:on("error", function(err)
    -- Something went wrong
end)

lobby:on("disconnected", function()
    -- Lost connection to the server
end)
```

## Disconnect & Reconnect

When a player's connection drops unexpectedly (crash, internet outage, game close), they aren't removed immediately. Instead, the server starts a **2-minute grace period** that reserves their lobby slot.

- **During grace period** — other players receive `player_disconnected`. The player's slot is reserved and their state is preserved.
- **If they reconnect** — the player slots back in seamlessly. Other players receive `player_reconnected`. No data is lost.
- **If the timer expires** — the player is removed from the lobby with `player_left`. If the lobby is now empty, it closes.
- **Explicit leave** — calling `lobby:leave()` removes the player immediately with no grace period.

### Host Disconnect

When the host disconnects:
- Host role transfers immediately to the next available player (`host_changed` event)
- The disconnected host's lobby slot is still reserved during the grace period
- If they reconnect, they rejoin as a regular player (not host)

### Player Away Status

Players in a grace period are marked as "away" in the player list:

```lua
local players = lobby:get_players()
-- { { id = "player_123", state = {...}, is_away = false },
--   { id = "player_456", state = {...}, is_away = true } }
```

### State Recovery

The server keeps each player's last state for the lobby, so it survives disconnects. When a player rejoins, the server sends them a snapshot that includes it.

Mod authors don't need to handle this manually. As long as game state is kept in player state via `lobby:set_player_state()`, it will be available on reconnect. The reconnecting client receives:

- Their own last state
- Current lobby metadata
- A `player_reconnected` event confirming they're back

## Configuration

MultiplayerAPI is configured via SMODS mod config (`config.lua`):

```lua
return {
    ["chat_enabled"] = false,           -- enable/disable built-in lobby chat
}
```

Values are accessible at `SMODS.current_mod.config.*`. The server is the production Nakama server unless one of these optional keys overrides it: `server_host`, `server_port`, `server_secure`, `nakama_server_key` and `web_url` (the website that "View Log" and report links open). `MPAPI.connect{ host = ..., port = ..., secure = ..., server_key = ..., web_url = ... }` opts take precedence over the config. Use 127.0.0.1 (not "localhost") on Windows.

Dev builds load `dev/init.lua` (stripped from releases), which points the game at the local server stack (Nakama on 127.0.0.1:7350) unless `BMP_SERVER_HOST` is set. `BMP_IMPERSONATE_ID`/`BMP_IMPERSONATE_NAME` log an instance in as another account with a Nakama device login.

Chat is handled entirely by MultiplayerAPI

## Architecture

MultiplayerAPI talks to a [Nakama](https://heroiclabs.com/nakama/) server (BalatroMultiplayerServer's `nakama/` module):

```
Game Client <-> Nakama (lobby matches, RPCs, notifications) -> PostgreSQL
                  |
                  +-> Express API (website, webadmin, moderation)
```

- **Login** sends the Steam ticket to Nakama, which checks it and opens a session; `session_init` returns the account.
- **Lobbies** are server-authoritative Nakama matches. Metadata, player state, actions, chat and the game's ready/start/result flow all go through the match, and the server stamps who sent each message.
- **Matchmaking** uses Nakama matchmaker tickets; ratings, replays and spectating are RPCs.
- **Server pushes** (account changes, bans, integrity challenges, config) arrive as Nakama notifications over the same socket.
- **Express** keeps the website and webadmin. Nakama mirrors finished games, ratings and chat logs into its Postgres tables.

All socket and HTTP I/O runs on dedicated `love.thread`s so the game loop never blocks. The mod author doesn't interact with any of this directly.

### Permissions

The Nakama match enforces access control:

- **Lobby isolation** - Players only receive messages from the lobby they joined.
- **Host-only metadata** - Only the host can update lobby metadata and start the game.
- **Private player state** - Players can only write their own state. Other players' state is not sent to them — use actions to share information.
- **Identity** - The server stamps each action and chat message with its sender, so players cannot impersonate each other.

## Installation

Requires [Steamodded](https://github.com/Steamopollys/Steamodded) >= 1.0.0 and [Lovely](https://github.com/ethangreen-dev/lovely-injector) >= 0.8.

Copy the `MultiplayerAPI/` folder into your Balatro Mods directory:

- **Windows:** `%AppData%/Balatro/Mods/`
- **Linux (Proton):** `~/.steam/steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods/`
- **macOS:** `~/Library/Application Support/Balatro/Mods/`

Add the dependency to your mod's JSON:

```json
{
  "dependencies": [
    "MultiplayerAPI (>=0.1.0)"
  ]
}
```

## License

See [LICENSE.md](LICENSE.md).
