#!/bin/bash
set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common.sh"

PORT=9341
RESTART_EXISTING=false
PROMPT_RESTART=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --restart-existing) RESTART_EXISTING=true; shift ;;
    --prompt-restart) PROMPT_RESTART=true; shift ;;
    *) fail "Unknown start argument: $1" ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Port must be between 1024 and 65535."
ensure_macos
[ -f "$ENGINE_ROOT/src/injector.mjs" ] || fail "Codex Native Dock is not installed."
discover_codex_app
validate_codex_signature
resolve_node
ensure_install_root

endpoint="$(find_endpoint "$PORT" 2>/dev/null || true)"
if [ -z "$endpoint" ]; then
  if codex_is_running; then
    if [ "$PROMPT_RESTART" = true ] && [ "$RESTART_EXISTING" = false ]; then
      /usr/bin/osascript - <<'APPLESCRIPT' >/dev/null || fail "Startup was cancelled."
display dialog "Codex must restart once to enable the quick dock. Save any unsent input first." buttons {"Cancel", "Restart"} default button "Restart" cancel button "Cancel" with title "Codex Native Dock"
APPLESCRIPT
      RESTART_EXISTING=true
    fi
    [ "$RESTART_EXISTING" = true ] || fail "Codex is open without a debugging endpoint. Close it first or approve the restart."
    stop_codex
  fi
  PORT="$(select_free_port)"
  launch_codex_with_cdp "$PORT"
  BROWSER_ID="$(wait_for_endpoint "$PORT")" || fail "Codex did not expose a verified loopback endpoint. See $APP_ERROR_LOG"
else
  PORT="${endpoint%% *}"
  BROWSER_ID="${endpoint#* }"
fi

stop_recorded_injector
/bin/rm -f "$STATE_PATH"
INJECTOR_PID="$(launch_injector "$PORT" "$BROWSER_ID")"
INJECTOR_STARTED_AT="$(process_started_at "$INJECTOR_PID")"
[ -n "$INJECTOR_STARTED_AT" ] || fail "Could not record the injector start time."
write_state "$PORT" "$BROWSER_ID" "$INJECTOR_PID" "$INJECTOR_STARTED_AT"
/bin/sleep 2
if ! "$NODE" "$ENGINE_ROOT/src/injector.mjs" --verify --port "$PORT" --browser-id "$BROWSER_ID"; then
  stop_recorded_injector
  fail "Live verification failed. See $INJECTOR_ERROR_LOG"
fi
printf 'Codex Native Dock %s is running on loopback port %s.\n' "$VERSION" "$PORT"
