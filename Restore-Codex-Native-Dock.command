#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
exec "$ROOT/macos/scripts/restore.sh" --remove-files --restart-codex
