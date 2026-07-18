#!/bin/bash
set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common.sh"

PORT=9341
IN_PLACE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --in-place) IN_PLACE=true; shift ;;
    *) fail "Unknown installer argument: $1" ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Port must be between 1024 and 65535."
ensure_macos

deploy_engine() {
  local temporary="$INSTALL_ROOT/engine.installing.$$" previous="$INSTALL_ROOT/engine.previous.$$"
  [ -z "$(/usr/bin/find "$PROJECT_ROOT" -type l -print -quit)" ] || fail "The extracted package contains a symbolic link and was rejected."
  ensure_install_root
  /bin/rm -rf "$temporary" "$previous"
  /bin/mkdir -p "$temporary/src" "$temporary/macos"
  /usr/bin/rsync -a --exclude '.DS_Store' "$PROJECT_ROOT/src/" "$temporary/src/"
  /usr/bin/rsync -a --exclude '.DS_Store' "$PROJECT_ROOT/macos/" "$temporary/macos/"
  for file in README.md LICENSE NOTICE.md SECURITY.md Install-Codex-Native-Dock.command Restore-Codex-Native-Dock.command; do
    [ ! -f "$PROJECT_ROOT/$file" ] || /bin/cp "$PROJECT_ROOT/$file" "$temporary/"
  done
  /bin/chmod 700 "$temporary"/macos/scripts/*.sh "$temporary"/*.command
  [ ! -e "$ENGINE_ROOT" ] || /bin/mv "$ENGINE_ROOT" "$previous"
  if ! /bin/mv "$temporary" "$ENGINE_ROOT"; then
    [ ! -e "$previous" ] || /bin/mv "$previous" "$ENGINE_ROOT"
    fail "Could not install files below $INSTALL_ROOT"
  fi
  /bin/rm -rf "$previous"
}

if [ "$IN_PLACE" = false ] || [ "$PROJECT_ROOT" != "$ENGINE_ROOT" ]; then
  deploy_engine
  exec "$ENGINE_ROOT/macos/scripts/install.sh" --in-place --port "$PORT"
fi

discover_codex_app
validate_codex_signature
resolve_node
"$NODE" --check "$ENGINE_ROOT/src/injector.mjs"
"$NODE" --check "$ENGINE_ROOT/src/renderer.js"
"$NODE" --check "$ENGINE_ROOT/src/usage-store.mjs"

/bin/mkdir -p "$HOME/Desktop"
write_launcher() {
  local target="$1" mode="$2"
  if [ -e "$target" ] && ! /usr/bin/grep -q '^# Codex Native Dock launcher$' "$target" 2>/dev/null; then
    fail "Refusing to overwrite an unrelated Desktop file: $target"
  fi
  if [ "$mode" = start ]; then
    /usr/bin/printf '%s\n' '#!/bin/bash' '# Codex Native Dock launcher' 'set -e' \
      'exec "$HOME/Library/Application Support/CodexNativeDock/engine/macos/scripts/start.sh" --prompt-restart' > "$target"
  else
    /usr/bin/printf '%s\n' '#!/bin/bash' '# Codex Native Dock launcher' 'set -e' \
      'exec "$HOME/Library/Application Support/CodexNativeDock/engine/macos/scripts/restore.sh" --remove-files --restart-codex' > "$target"
  fi
  /bin/chmod 700 "$target"
}

write_launcher "$HOME/Desktop/Codex Native Dock.command" start
write_launcher "$HOME/Desktop/Restore Codex Native Dock.command" restore
"$ENGINE_ROOT/macos/scripts/start.sh" --port "$PORT" --prompt-restart

/usr/bin/osascript - <<'APPLESCRIPT' >/dev/null 2>&1 || true
display alert "Installation complete" message "Codex Native Dock is active. Use the new Desktop launcher whenever Codex is updated or opened without the dock."
APPLESCRIPT
printf 'Codex Native Dock %s installed successfully.\n' "$VERSION"
