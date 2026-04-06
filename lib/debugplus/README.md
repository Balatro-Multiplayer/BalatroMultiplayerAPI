# DebugPlus — Extracted Console Component

These files were copied from [WilsontheWolf/DebugPlus](https://github.com/WilsontheWolf/DebugPlus)
on **March 30, 2026 at 6:00 PM PST**.

All credit to **[WilsontheWolf](https://github.com/WilsontheWolf)** for the original implementation.

These files are licensed under the [Mozilla Public License 2.0](LICENSE).
The rest of the BalatroMultiplayerAPI mod is independently licensed — the MPL-2.0
copyleft applies only to the files in this directory.

---

## Files and Modifications

### `unicode.lua`
Copied verbatim. No functional or structural changes.

### `util.lua`
Stripped down to only the functions needed by `ui.lua` and `console.lua`.

**Removed:**
- `stringifyTable`
- `hasValue`
- `split`
- `pack`
- `escapeSimple`
- `unescapeSimple`

**Kept:** `ctrlText`, `isMac`, `isCtrlDown`, `isShiftDown`, `trim`

### `ui.lua`
Changed `require` paths to resolve relative to the BMP mod root:
- `require "debugplus.util"` → `require "lib.debugplus.util"`
- `require "debugplus.unicode"` → `require "lib.debugplus.unicode"`

No other changes.

### `console.lua`
Heavily stripped and modified for use as a standalone in-game chat overlay,
with no dependency on the rest of DebugPlus. Loaded at runtime via
`MPAPI.load_mpapi_file` rather than `require`, so it is only instantiated
when DebugPlus is not installed.

**Removed:**
- All `require` dependencies on `debugplus.logger`, `debugplus.config`, `debugplus.watcher`
- All built-in commands (`echo`, `help`, `eval`, `money`, `round`, `ante`, `discards`, `hands`, `watch`, `tutorial`, `resetshop`, `value`) and the command dispatch system entirely
- Command history state (`history`, `currentHistory`) and persistence (`loadHistory`, `saveHistory`)
- `hyjackErrorHandler` and its call in `doConsoleRender`
- `registerCommand` / external command registration API
- `isConsoleFocused` (replaced with `isOpen`)
- `handleLogsChange` callback wiring
- `showNewLogs` config toggle (Shift+/ behaviour)
- Level-based log filtering and `onlyCommands` config check
- Log level prefix display (`[I]`, `[W]`, etc.) in the render loop
- All `logger.*` and `config.*` references

**Changed:**
- `require` paths updated to BMP mod root equivalents (`lib.debugplus.util`, `lib.debugplus.ui`)
- `hookStuffs()` moved before the early-return guard so keybinds are registered on the first rendered frame even when there are no messages yet
- Open key changed from `/` to `t`
- `runCommand()` replaced with `sendMessage()`, which invokes a configurable callback
- Log store changed from `logger.logs` to a local `messages` table with simplified `{str, time, colour}` entries
- `firstConsoleRender` timestamp logic replaced with a simple `initialized` boolean flag for hook setup
- History navigation (Up/Down keys) removed from `consoleHandleKey`
- Shift+key toggle of `showNewLogs` removed from `consoleHandleKey`
- `wheelmoved` scroll bound changed from `#logger.logs` to `#messages`
- Message cap reduced from 5000 to 500

**Added:**
- `local messages` — chat message store (replaces `logger.logs`)
- `local sendCallback` — callback invoked when the user submits a message
- `global.addMessage(str, colour)` — push a `{str, time, colour}` entry into the display
- `global.setSendCallback(fn)` — register the send callback
- `global.isOpen()` — returns whether the chat input box is currently open (replaces `isConsoleFocused`)
