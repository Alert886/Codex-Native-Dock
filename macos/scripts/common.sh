#!/bin/bash
set -euo pipefail

if [ -z "${HOME:-}" ]; then
  CURRENT_USER="$(/usr/bin/id -un)"
  HOME="$(/usr/bin/dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
  [ -n "$HOME" ] || { printf 'Codex Native Dock: could not resolve the current home directory.\n' >&2; exit 1; }
  export HOME
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
INSTALL_ROOT="$HOME/Library/Application Support/CodexNativeDock"
ENGINE_ROOT="$INSTALL_ROOT/engine"
STATE_PATH="$INSTALL_ROOT/state.json"
RUNTIME_ROOT="$INSTALL_ROOT/runtime"
INJECTOR_LOG="$INSTALL_ROOT/injector.log"
INJECTOR_ERROR_LOG="$INSTALL_ROOT/injector-error.log"
APP_LOG="$INSTALL_ROOT/codex-launch.log"
APP_ERROR_LOG="$INSTALL_ROOT/codex-launch-error.log"
VERSION="0.2.0"
EXPECTED_CODEX_TEAM_ID="${CODEX_EXPECTED_TEAM_ID:-2DC432GLL2}"

fail() {
  printf 'Codex Native Dock: %s\n' "$*" >&2
  exit 1
}

ensure_macos() {
  [ "$(/usr/bin/uname -s)" = "Darwin" ] || fail "This installer requires macOS."
}

ensure_install_root() {
  /bin/mkdir -p "$INSTALL_ROOT"
  /bin/chmod 700 "$INSTALL_ROOT"
}

path_is_within() {
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

discover_codex_app() {
  local candidate identifier executable_name configured="${CODEX_APP_BUNDLE:-}"
  CODEX_BUNDLE=""
  for candidate in "$configured" \
    "/Applications/ChatGPT.app" "$HOME/Applications/ChatGPT.app" \
    "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate/Contents/Info.plist" ] || continue
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$identifier" = "com.openai.codex" ]; then CODEX_BUNDLE="$candidate"; break; fi
  done
  if [ -z "$CODEX_BUNDLE" ]; then
    candidate="$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' | /usr/bin/head -n 1)"
    if [ -n "$candidate" ] && [ -f "$candidate/Contents/Info.plist" ]; then
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
      [ "$identifier" = "com.openai.codex" ] && CODEX_BUNDLE="$candidate"
    fi
  fi
  [ -n "$CODEX_BUNDLE" ] || fail "The official Codex app (com.openai.codex) was not found."
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$CODEX_BUNDLE/Contents/Info.plist")"
  CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/$executable_name"
  CODEX_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$CODEX_BUNDLE/Contents/Info.plist")"
  [ -x "$CODEX_EXE" ] || fail "The Codex executable is missing: $CODEX_EXE"
  export CODEX_BUNDLE CODEX_EXE CODEX_VERSION
}

codesign_team_id() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

validate_codex_signature() {
  /usr/bin/codesign --verify --deep --strict "$CODEX_BUNDLE" >/dev/null 2>&1 \
    || fail "The Codex app signature is invalid. Reinstall the official app first."
  CODEX_TEAM_ID="$(codesign_team_id "$CODEX_BUNDLE")"
  [ "$CODEX_TEAM_ID" = "$EXPECTED_CODEX_TEAM_ID" ] \
    || fail "Unexpected Codex signing team: ${CODEX_TEAM_ID:-missing}."
  export CODEX_TEAM_ID
}

node_major() {
  local value major
  value="$("$1" --version 2>/dev/null || true)"
  major="${value#v}"; major="${major%%.*}"
  case "$major" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$major" ;; esac
}

install_portable_node() {
  local machine_arch archive_arch base checksums name expected temporary archive extracted actual
  machine_arch="$(/usr/bin/uname -m)"
  case "$machine_arch" in arm64) archive_arch="arm64" ;; x86_64) archive_arch="x64" ;; *) fail "Unsupported Mac architecture: $machine_arch" ;; esac
  base="https://nodejs.org/dist/latest-v22.x"
  checksums="$(/usr/bin/curl --fail --location --silent --show-error --max-time 45 "$base/SHASUMS256.txt")"
  name="$(printf '%s\n' "$checksums" | /usr/bin/awk -v arch="$archive_arch" '$2 ~ ("^node-v22\\.[0-9.]+-darwin-" arch "\\.tar\\.gz$") { print $2; exit }')"
  expected="$(printf '%s\n' "$checksums" | /usr/bin/awk -v file="$name" '$2 == file { print $1; exit }')"
  [ -n "$name" ] && [ -n "$expected" ] || fail "No official Node.js 22 archive was listed for this Mac."
  temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-native-dock-node.XXXXXX")"
  archive="$temporary/$name"
  extracted="$temporary/extracted"
  /bin/mkdir -p "$extracted"
  /usr/bin/curl --fail --location --silent --show-error --max-time 240 "$base/$name" -o "$archive"
  actual="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  [ "$actual" = "$expected" ] || { /bin/rm -rf "$temporary"; fail "The Node.js SHA-256 checksum did not match nodejs.org."; }
  /usr/bin/tar -xzf "$archive" -C "$extracted"
  local node_root
  node_root="$(/bin/ls -d "$extracted"/node-v22.*-darwin-"$archive_arch" 2>/dev/null | /usr/bin/head -n 1)"
  [ -x "$node_root/bin/node" ] || { /bin/rm -rf "$temporary"; fail "The Node.js archive was incomplete."; }
  ensure_install_root
  /bin/rm -rf "$RUNTIME_ROOT.new" "$RUNTIME_ROOT.old"
  /bin/mv "$node_root" "$RUNTIME_ROOT.new"
  [ ! -e "$RUNTIME_ROOT" ] || /bin/mv "$RUNTIME_ROOT" "$RUNTIME_ROOT.old"
  /bin/mv "$RUNTIME_ROOT.new" "$RUNTIME_ROOT"
  /bin/rm -rf "$RUNTIME_ROOT.old" "$temporary"
}

resolve_node() {
  local candidate bundled
  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ "$(node_major "$candidate")" -ge 22 ]; then NODE="$candidate"; fi
  bundled="$CODEX_BUNDLE/Contents/Resources/cua_node/bin/node"
  if [ -z "${NODE:-}" ] && [ -x "$bundled" ] && [ "$(node_major "$bundled")" -ge 22 ]; then
    /usr/bin/codesign --verify --strict "$bundled" >/dev/null 2>&1 || fail "The bundled Node.js signature is invalid."
    [ "$(codesign_team_id "$bundled")" = "$CODEX_TEAM_ID" ] || fail "The bundled Node.js signer does not match Codex."
    NODE="$bundled"
  fi
  if [ -z "${NODE:-}" ] && [ -x "$RUNTIME_ROOT/bin/node" ] && [ "$(node_major "$RUNTIME_ROOT/bin/node")" -ge 22 ]; then
    NODE="$RUNTIME_ROOT/bin/node"
  fi
  if [ -z "${NODE:-}" ]; then install_portable_node; NODE="$RUNTIME_ROOT/bin/node"; fi
  NODE_VERSION="$("$NODE" --version)"
  export NODE NODE_VERSION
}

codex_main_pids() {
  local pid command_line
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in "$CODEX_EXE"*) printf '%s\n' "$pid" ;; esac
  done < <(/bin/ps -axo pid=,command=)
}

codex_is_running() { [ -n "$(codex_main_pids)" ]; }

stop_codex() {
  local deadline pid
  codex_is_running || return 0
  /usr/bin/osascript -e 'tell application id "com.openai.codex" to quit' >/dev/null 2>&1 || true
  deadline=$((SECONDS + 12))
  while codex_is_running && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.25; done
  if codex_is_running; then
    while IFS= read -r pid; do [ -z "$pid" ] || /bin/kill -TERM "$pid" 2>/dev/null || true; done < <(codex_main_pids)
  fi
  deadline=$((SECONDS + 5))
  while codex_is_running && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.25; done
  codex_is_running && fail "Codex could not be stopped safely."
}

listener_pids() { /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | /usr/bin/sort -u || true; }

pid_is_codex_descendant() {
  local current="$1" command_line parent depth=0
  while [ "$current" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
    command_line="$(/bin/ps -p "$current" -o command= 2>/dev/null || true)"
    case "$command_line" in "$CODEX_EXE"*) return 0 ;; esac
    parent="$(/bin/ps -p "$current" -o ppid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" -ne "$current" ] || return 1
    current="$parent"; depth=$((depth + 1))
  done
  return 1
}

port_belongs_to_codex() {
  local port="$1" pid found=false
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    found=true
    pid_is_codex_descendant "$pid" || return 1
  done < <(listener_pids "$port")
  [ "$found" = true ]
}

browser_identity() {
  local port="$1"
  port_belongs_to_codex "$port" || return 1
  "$NODE" --input-type=module - "$port" <<'NODE'
const port = Number(process.argv[2]);
try {
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const socket = new URL(version.webSocketDebuggerUrl);
  if (socket.protocol !== "ws:" || !["127.0.0.1", "localhost", "[::1]", "::1"].includes(socket.hostname)) process.exit(1);
  if (Number(socket.port || 80) !== port || !socket.pathname.startsWith("/devtools/browser/")) process.exit(1);
  const id = decodeURIComponent(socket.pathname.slice("/devtools/browser/".length));
  if (!/^[A-Za-z0-9._:-]{1,256}$/.test(id)) process.exit(1);
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  if (!targets.some((item) => item?.type === "page" && ["app://-/index.html", "app://codex/"].includes(item.url))) process.exit(1);
  process.stdout.write(id);
} catch { process.exit(1); }
NODE
}

port_is_free() { [ -z "$(listener_pids "$1")" ]; }

select_free_port() {
  local candidate
  for candidate in $(/usr/bin/jot - 9341 9355); do if port_is_free "$candidate"; then printf '%s\n' "$candidate"; return 0; fi; done
  fail "No free loopback debugging port was found from 9341 through 9355."
}

state_field() {
  [ -f "$STATE_PATH" ] || return 1
  "$NODE" -e 'const fs=require("node:fs");const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[process.argv[2]];if(v!==undefined&&v!==null)process.stdout.write(String(v));' "$STATE_PATH" "$1"
}

find_endpoint() {
  local preferred="${1:-9341}" candidate identity saved=""
  [ ! -f "$STATE_PATH" ] || saved="$(state_field port 2>/dev/null || true)"
  for candidate in "$saved" "$preferred" $(/usr/bin/jot - 9335 9355); do
    case "$candidate" in ''|*[!0-9]*) continue ;; esac
    identity="$(browser_identity "$candidate" 2>/dev/null || true)"
    if [ -n "$identity" ]; then printf '%s %s\n' "$candidate" "$identity"; return 0; fi
  done
  return 1
}

process_started_at() { /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'; }

recorded_injector_matches() {
  local pid="$1" started="$2" node="$3" injector="$4" port="$5" command actual
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in "$node"\ "$injector"\ --watch\ --port\ "$port"\ --browser-id\ *) ;; *) return 1 ;; esac
  actual="$(process_started_at "$pid")"
  [ -n "$actual" ] && [ "$actual" = "$started" ]
}

stop_recorded_injector() {
  [ -f "$STATE_PATH" ] || return 0
  local pid started node injector port deadline
  pid="$(state_field injectorPid 2>/dev/null || true)"
  started="$(state_field injectorStartedAt 2>/dev/null || true)"
  node="$(state_field nodePath 2>/dev/null || true)"
  injector="$(state_field injectorPath 2>/dev/null || true)"
  port="$(state_field port 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) fail "The saved injector identity is incomplete; refusing to signal an unknown process." ;; esac
  /bin/kill -0 "$pid" 2>/dev/null || return 0
  recorded_injector_matches "$pid" "$started" "$node" "$injector" "$port" \
    || fail "The saved injector PID belongs to another process; it was not stopped."
  /bin/kill -TERM "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 6))
  while /bin/kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.2; done
  if recorded_injector_matches "$pid" "$started" "$node" "$injector" "$port"; then /bin/kill -KILL "$pid" 2>/dev/null || true; fi
}

launch_codex_with_cdp() {
  local port="$1"
  : > "$APP_LOG"; : > "$APP_ERROR_LOG"
  /usr/bin/open -na "$CODEX_BUNDLE" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port="$port" \
    >>"$APP_LOG" 2>>"$APP_ERROR_LOG" || true
}

wait_for_endpoint() {
  local port="$1" deadline=$((SECONDS + 45)) identity
  while [ "$SECONDS" -lt "$deadline" ]; do
    identity="$(browser_identity "$port" 2>/dev/null || true)"
    if [ -n "$identity" ]; then printf '%s\n' "$identity"; return 0; fi
    /bin/sleep 0.35
  done
  return 1
}

launch_injector() {
  local port="$1" browser_id="$2" injector="$ENGINE_ROOT/src/injector.mjs" pid
  : > "$INJECTOR_LOG"; : > "$INJECTOR_ERROR_LOG"
  /usr/bin/nohup "$NODE" "$injector" --watch --port "$port" --browser-id "$browser_id" \
    >>"$INJECTOR_LOG" 2>>"$INJECTOR_ERROR_LOG" &
  pid="$!"; /bin/sleep 0.2
  /bin/kill -0 "$pid" 2>/dev/null || fail "The injector stopped during startup. See $INJECTOR_ERROR_LOG"
  printf '%s\n' "$pid"
}

write_state() {
  local port="$1" browser_id="$2" pid="$3" started="$4" injector="$ENGINE_ROOT/src/injector.mjs"
  "$NODE" - "$STATE_PATH" "$VERSION" "$port" "$browser_id" "$pid" "$started" "$injector" "$NODE" "$NODE_VERSION" "$CODEX_BUNDLE" "$CODEX_EXE" "$CODEX_VERSION" <<'NODE'
const fs = require("node:fs");
const [file, version, port, browserId, pid, startedAt, injectorPath, nodePath, nodeVersion, codexBundle, codexExe, codexVersion] = process.argv.slice(2);
const state = {schemaVersion:1,platform:"macos",version,port:Number(port),browserId,injectorPid:Number(pid),injectorStartedAt:startedAt,injectorPath,nodePath,nodeVersion,codexBundle,codexExe,codexVersion,createdAt:new Date().toISOString()};
const temporary = `${file}.${process.pid}.tmp`;
fs.writeFileSync(temporary, `${JSON.stringify(state,null,2)}\n`, {mode:0o600});
fs.renameSync(temporary,file);
NODE
}
