import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

const renderer = await fs.readFile(new URL("../src/renderer.js", import.meta.url), "utf8");
const css = await fs.readFile(new URL("../src/native-dock.css", import.meta.url), "utf8");
const injector = await fs.readFile(new URL("../src/injector.mjs", import.meta.url), "utf8");

test("one root owns both the usage meter and quick controls", () => {
  assert.match(renderer, /codex-native-dock-root/);
  assert.match(renderer, /root\.append\(usage, tools\)/);
  assert.doesNotMatch(renderer, /createPortal|elementFromPoint/);
});

test("native account quota scan is bounded and avoids a full body query", () => {
  assert.match(renderer, /__reactFiber/);
  assert.match(renderer, /inspectedObjects > 16000/);
  assert.match(renderer, /inspectedFibers < 14000/);
  assert.doesNotMatch(renderer, /querySelectorAll\(["']body \*["']\)/);
  assert.match(renderer, /codex-native-account-state/);
});

test("meter follows the live composer without geometry transitions", () => {
  assert.match(renderer, /ResizeObserver/);
  assert.match(renderer, /composer\.getBoundingClientRect\(\)/);
  assert.match(renderer, /translate3d/);
  assert.match(renderer, /setProperty\("width", `\$\{width\}px`, "important"\)/);
  assert.match(css, /#codex-native-dock-root \.cnd-usage[\s\S]*?transition: none !important/);
});

test("palette remains fixed", () => {
  assert.match(css, /--cnd-bg: rgb\(24 24 27/);
  assert.match(renderer, /adaptiveTheme: false/);
  assert.doesNotMatch(renderer, /active-theme|wallpaper|data-theme|prefers-color-scheme/);
});

test("ChatGPT hides quota while controls remain available", () => {
  assert.match(renderer, /if \(isChatGpt\(\)\)[\s\S]*?usage\.hidden = true/);
  assert.match(renderer, /makeTool\(tools, "focus"/);
  assert.match(renderer, /makeTool\(tools, "sidebar"/);
  assert.match(renderer, /makeTool\(tools, "top"/);
  assert.match(renderer, /makeTool\(tools, "bottom"/);
});

test("injector accepts only loopback Codex page endpoints", () => {
  assert.match(injector, /127\.0\.0\.1/);
  assert.match(injector, /app:\/\/-\/index\.html/);
  assert.match(injector, /\/devtools\/page\//);
  assert.doesNotMatch(injector, /0\.0\.0\.0.*fetch/);
});

test("watcher reapplies the component after a full page reload", () => {
  assert.match(injector, /Page\.loadEventFired/);
  assert.match(injector, /await session\.send\("Page\.enable"\)/);
  assert.match(injector, /await session\.evaluate\(payload\)/);
});
