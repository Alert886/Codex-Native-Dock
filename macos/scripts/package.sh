#!/bin/bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
VERSION="$(/usr/bin/sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/package.json" | /usr/bin/head -n 1)"
[ -n "$VERSION" ] || { printf 'Could not read package version.\n' >&2; exit 1; }
OUTPUT="${1:-$ROOT/dist/Codex-Native-Dock-macOS-v$VERSION.zip}"
TEMPORARY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-native-dock-package.XXXXXX")"
STAGE="$TEMPORARY/Codex-Native-Dock-v$VERSION"
trap '/bin/rm -rf "$TEMPORARY"' EXIT
/bin/mkdir -p "$STAGE/src" "$STAGE/macos/scripts" "$(/usr/bin/dirname "$OUTPUT")"
/usr/bin/rsync -a "$ROOT/src/" "$STAGE/src/"
/usr/bin/rsync -a "$ROOT/macos/" "$STAGE/macos/"
for file in Install-Codex-Native-Dock.command Restore-Codex-Native-Dock.command README.md LICENSE NOTICE.md SECURITY.md; do
  /bin/cp "$ROOT/$file" "$STAGE/"
done
/bin/chmod 755 "$STAGE"/*.command "$STAGE"/macos/scripts/*.sh
(
  cd "$STAGE"
  /usr/bin/find . -type f ! -name MANIFEST.sha256 | /usr/bin/sort | while IFS= read -r file; do
    /usr/bin/shasum -a 256 "$file"
  done > MANIFEST.sha256
)
/usr/bin/xattr -cr "$STAGE" 2>/dev/null || true
/bin/rm -f "$OUTPUT"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$STAGE" "$OUTPUT"
printf 'Created %s\nSHA-256 %s\n' "$OUTPUT" "$(/usr/bin/shasum -a 256 "$OUTPUT" | /usr/bin/awk '{print $1}')"
