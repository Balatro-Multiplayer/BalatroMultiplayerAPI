#!/usr/bin/env bash
# Run one in-game scenario and exit 0 only if it passed (macOS).
#
#   cd <mod checkout> && bash <MPAPI checkout>/scripts/run_scenario.sh MultiplayerPvP:smoke
#
# Installed Mods must point at both checkouts; this script never changes links.
# Env: MOD_REPO (default $PWD), BALATRO_DIR, SCENARIO_TIMEOUT (seconds, default 120).
set -euo pipefail

SELECTOR="${1:?usage: run_scenario.sh <mod_id>:<name>}"
MOD_ID="${SELECTOR%%:*}"
NAME="${SELECTOR#*:}"
API_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MOD_REPO="$(cd "${MOD_REPO:-$PWD}" && pwd -P)"
MODS="$HOME/Library/Application Support/Balatro/Mods"
GAME_DIR="${BALATRO_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/Balatro}"
TIMEOUT="${SCENARIO_TIMEOUT:-120}"

die() {
  printf 'scenario: %s\n' "$*" >&2
  exit 1
}

check_args() {
  [[ $# -eq 1 ]] || die "expected one <mod_id>:<name> argument"
  [[ "$SELECTOR" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]] || die "expected <mod_id>:<name>"
  [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "SCENARIO_TIMEOUT must be positive whole seconds"
  [[ -f "$GAME_DIR/run_lovely_macos.sh" ]] || die "missing $GAME_DIR/run_lovely_macos.sh"
  [[ -f "$MOD_REPO/tests/scenarios/$NAME.lua" ]] || die "no tests/scenarios/$NAME.lua in $MOD_REPO"
}

# Exactly one installed copy, located by a manifest named <id>.json.
check_installed() {
  local id="$1" repo="$2" found=0 entry target
  for entry in "$MODS"/*; do
    [[ -d "$entry" && -f "$entry/$id.json" ]] || continue
    target="$(cd "$entry" && pwd -P)"
    printf '%s: %s -> %s\n' "$id" "$entry" "$target"
    [[ "$target" == "$repo" ]] || die "$id is installed from the wrong checkout; expected $repo"
    found=$((found + 1))
  done
  [[ "$found" -eq 1 ]] || die "expected one installed $id, found $found"
}

check_not_running() {
  if pgrep -f 'Balatro.app/Contents/MacOS/love' >/dev/null; then
    die "Balatro is already running"
  fi
}

# Kill only this run's game: the launch script's child, then the script itself.
stop_game() {
  [[ -n "${game_pid:-}" ]] || return 0
  pkill -KILL -P "$game_pid" 2>/dev/null || true
  kill -KILL "$game_pid" 2>/dev/null || true
  wait "$game_pid" 2>/dev/null || true
  game_pid=
}

cleanup() {
  stop_game
  if [[ -n "${caffeinate_pid:-}" ]]; then
    kill "$caffeinate_pid" 2>/dev/null || true
  fi
}

launch() {
  # caffeinate must not inherit stdout, or a calling shell waits on it.
  caffeinate -u -t "$TIMEOUT" >/dev/null 2>&1 &
  caffeinate_pid=$!
  BMP_SCENARIO="$SELECTOR" BMP_SCENARIO_QUIT=1 BMP_SCENARIO_RUN_ID="$RUN_ID" \
    bash "$GAME_DIR/run_lovely_macos.sh" >"$RUN_DIR/launch.log" 2>&1 &
  game_pid=$!
}

# Sets game_status: the game's exit code, or "timeout".
wait_for_exit() {
  local second
  for ((second=0; second<TIMEOUT; second++)); do
    if ! kill -0 "$game_pid" 2>/dev/null; then
      game_status=0
      wait "$game_pid" || game_status=$?
      game_pid=
      return
    fi
    sleep 1
  done
  game_status=timeout
  stop_game
}

find_log() {
  local newest= candidate
  for candidate in "$MODS/lovely/log/"*; do
    [[ -f "$candidate" && "$candidate" -nt "$RUN_DIR/started" ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then newest="$candidate"; fi
  done
  [[ -n "$newest" ]] || die "no Lovely log from this run"
  printf '%s\n' "$newest"
}

verdict() {
  local results="$1"
  [[ "$game_status" == 0 ]] || die "game did not exit cleanly ($game_status)"
  grep -Fxq "BMP_SCENARIO START $SELECTOR run=$RUN_ID" "$results" || die "scenario never started"
  if grep -q '^BMP_SCENARIO FAIL ' "$results"; then die "scenario failed"; fi
  grep -Eq '^BMP_SCENARIO DONE pass=[1-9][0-9]* fail=0$' "$results" || die "no passing DONE line"
}

check_args "$@"
check_installed MultiplayerAPI "$API_REPO"
check_installed "$MOD_ID" "$MOD_REPO"
check_not_running
printf 'API %s, %s %s\n' "$(git -C "$API_REPO" rev-parse --short HEAD)" \
  "$MOD_ID" "$(git -C "$MOD_REPO" rev-parse --short HEAD)"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bmp-scenario.XXXXXX")"
RUN_ID="${RUN_DIR##*/}"
touch "$RUN_DIR/started"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

launch
wait_for_exit

LOG="$(find_log)"
grep -o 'BMP_SCENARIO .*' "$LOG" | \
  awk -v start="BMP_SCENARIO START $SELECTOR run=$RUN_ID" \
    '{ sub(/[[:space:]]+$/, "") } $0 == start { started=1 } started { print }' \
  >"$RUN_DIR/results" || true
cat "$RUN_DIR/results"
printf 'Lovely log: %s\nlaunch output: %s/launch.log\n' "$LOG" "$RUN_DIR"
verdict "$RUN_DIR/results"
