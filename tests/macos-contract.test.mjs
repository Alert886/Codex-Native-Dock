import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const common = read("macos/scripts/common.sh");
const install = read("macos/scripts/install.sh");
const start = read("macos/scripts/start.sh");
const restore = read("macos/scripts/restore.sh");
const pack = read("macos/scripts/package.sh");

test("macOS discovers and verifies the official Codex bundle", () => {
  assert.match(common, /com\.openai\.codex/);
  assert.match(common, /codesign --verify --deep --strict/);
  assert.match(common, /EXPECTED_CODEX_TEAM_ID/);
});

test("macOS CDP remains loopback-only and process-owned", () => {
  assert.match(common, /remote-debugging-address=127\.0\.0\.1/);
  assert.match(common, /port_belongs_to_codex/);
  assert.match(common, /devtools\/browser/);
  assert.match(start, /browser_id|BROWSER_ID/);
});

test("macOS Node fallback uses official checksums", () => {
  assert.match(common, /https:\/\/nodejs\.org\/dist\/latest-v22\.x/);
  assert.match(common, /SHASUMS256\.txt/);
  assert.match(common, /shasum -a 256/);
});

test("macOS install and restore stay outside the app bundle", () => {
  assert.match(common, /Library\/Application Support\/CodexNativeDock/);
  assert.match(install, /ENGINE_ROOT/);
  assert.match(restore, /path_is_within/);
  for (const source of [common, install, start, restore]) {
    assert.doesNotMatch(source, /(?:cp|mv|rm).*CODEX_BUNDLE/);
    assert.doesNotMatch(source, /app\.asar/);
  }
});

test("macOS cleanup validates the recorded injector identity", () => {
  assert.match(common, /recorded_injector_matches/);
  assert.match(common, /injectorStartedAt/);
  assert.match(common, /injectorPath/);
  assert.match(common, /refusing to signal an unknown process/i);
});

test("macOS package preserves command permissions", () => {
  assert.match(pack, /chmod 755/);
  assert.match(pack, /ditto -c -k --keepParent/);
  assert.match(pack, /MANIFEST\.sha256/);
});
