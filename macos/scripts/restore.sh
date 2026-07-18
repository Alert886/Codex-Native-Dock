#!/bin/bash
set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common.sh"

REMOVE_FILES=false
RESTART_CODEX=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remove-files) REMOVE_FILES=true; shift ;;
    --restart-codex) RESTART_CODEX=true; shift ;;
    *) fail "Unknown restore argument: $1" ;;
  esac
done
ensure_macos
discover_codex_app
validate_codex_signature
resolve_node

PORT="$(state_field port 2>/dev/null || true)"
BROWSER_ID="$(state_field browserId 2>/dev/null || true)"
stop_recorded_injector
if [ -n "$PORT" ] && [ -n "$BROWSER_ID" ] && [ -f "$ENGINE_ROOT/src/injector.mjs" ]; then
  "$NODE" "$ENGINE_ROOT/src/injector.mjs" --remove --port "$PORT" --browser-id "$BROWSER_ID" >/dev/null 2>&1 || true
fi
/bin/rm -f "$STATE_PATH"

WAS_RUNNING=false
codex_is_running && WAS_RUNNING=true
if [ "$RESTART_CODEX" = true ] && [ "$WAS_RUNNING" = true ]; then stop_codex; fi
/bin/rm -f "$HOME/Desktop/Codex Native Dock.command" "$HOME/Desktop/Restore Codex Native Dock.command"
if [ "$REMOVE_FILES" = true ]; then
  path_is_within "$INSTALL_ROOT" "$HOME/Library/Application Support" \
    || fail "Refusing to remove an unexpected path."
  [ "$(/usr/bin/basename "$INSTALL_ROOT")" = "CodexNativeDock" ] || fail "Refusing to remove an unexpected directory."
  /bin/rm -rf "$INSTALL_ROOT"
fi
if [ "$RESTART_CODEX" = true ] && [ "$WAS_RUNNING" = true ]; then /usr/bin/open -na "$CODEX_BUNDLE"; fi
printf 'Codex Native Dock was removed. Codex itself was not modified.\n'
