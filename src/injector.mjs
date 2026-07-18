#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { readUsage } from "./usage-store.mjs";

const VERSION = "0.1.0";
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);
const PAGE_URLS = new Set(["app://-/index.html", "app://codex/"]);
const PAGE_ID = /^[A-Za-z0-9._:-]{1,256}$/;
const BROWSER_ID = /^[A-Za-z0-9._:-]{1,256}$/;
const here = path.dirname(fileURLToPath(import.meta.url));

function parseOptions(argv) {
  const options = { port: 9341, mode: "watch", browserId: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--once") options.mode = "once";
    else if (argument === "--watch") options.mode = "watch";
    else if (argument === "--remove") options.mode = "remove";
    else if (argument === "--verify") options.mode = "verify";
    else if (argument === "--self-test") options.mode = "self-test";
    else if (argument === "--port") options.port = Number(argv[++index]);
    else if (argument === "--browser-id") options.browserId = String(argv[++index] || "");
    else if (argument === "--help" || argument === "-h") options.mode = "help";
    else throw new Error(`Unknown option: ${argument}`);
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error("Port must be an integer from 1024 through 65535");
  }
  if (options.browserId && !BROWSER_ID.test(options.browserId)) throw new Error("Invalid browser identity");
  return options;
}

function printHelp() {
  console.log([
    "Codex Native Dock injector",
    "",
    "  --watch       keep the dock present after navigation (default)",
    "  --once        inject into current Codex pages and exit",
    "  --remove      remove the dock from current Codex pages",
    "  --verify      verify DOM presence and composer alignment",
    "  --self-test   run endpoint-validation tests",
    "  --port N      loopback DevTools port (default 9341)",
    "  --browser-id  expected DevTools browser identity",
  ].join("\n"));
}

function validateSocketUrl(raw, port, kind, expectedId = "") {
  const url = new URL(String(raw || ""));
  if (url.protocol !== "ws:" || !LOOPBACK_HOSTS.has(url.hostname)) throw new Error("DevTools endpoint is not loopback WebSocket");
  if (url.username || url.password || url.search || url.hash) throw new Error("Unexpected DevTools endpoint components");
  if (Number(url.port || 80) !== port) throw new Error("DevTools port mismatch");
  const prefix = kind === "browser" ? "/devtools/browser/" : "/devtools/page/";
  if (!url.pathname.startsWith(prefix)) throw new Error(`Unexpected ${kind} endpoint path`);
  const identity = decodeURIComponent(url.pathname.slice(prefix.length));
  const pattern = kind === "browser" ? BROWSER_ID : PAGE_ID;
  if (!pattern.test(identity) || (expectedId && identity !== expectedId)) throw new Error(`${kind} identity mismatch`);
  return { url: url.toString(), identity };
}

async function fetchJson(port, resource) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${resource}`, {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error(`DevTools ${resource} returned HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function validateBrowser(port, expectedBrowserId) {
  const version = await fetchJson(port, "/json/version");
  const endpoint = validateSocketUrl(version?.webSocketDebuggerUrl, port, "browser");
  if (expectedBrowserId && endpoint.identity !== expectedBrowserId) throw new Error("DevTools browser identity changed");
  return endpoint.identity;
}

function selectTargets(items, port) {
  if (!Array.isArray(items)) return [];
  const selected = [];
  for (const item of items) {
    if (item?.type !== "page" || !PAGE_URLS.has(item.url) || !PAGE_ID.test(String(item.id || ""))) continue;
    try {
      const endpoint = validateSocketUrl(item.webSocketDebuggerUrl, port, "page", String(item.id));
      selected.push({ id: String(item.id), url: item.url, socketUrl: endpoint.url });
    } catch {}
  }
  return selected;
}

class CdpSession {
  constructor(socketUrl) {
    this.socketUrl = socketUrl;
    this.socket = null;
    this.counter = 0;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async open() {
    this.socket = new WebSocket(this.socketUrl);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("DevTools WebSocket timed out")), 4000);
      this.socket.addEventListener("open", () => { clearTimeout(timeout); resolve(); }, { once: true });
      this.socket.addEventListener("error", () => { clearTimeout(timeout); reject(new Error("DevTools WebSocket failed")); }, { once: true });
    });
    this.socket.addEventListener("message", (event) => this.#handle(event));
    this.socket.addEventListener("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("DevTools WebSocket closed"));
      this.pending.clear();
      this.emit("close", {});
    });
    return this;
  }

  #handle(event) {
    let message;
    try { message = JSON.parse(String(event.data)); } catch { return; }
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) pending.reject(new Error(message.error.message || "CDP request failed"));
      else pending.resolve(message.result);
      return;
    }
    if (message.method) this.emit(message.method, message.params || {});
  }

  on(event, handler) {
    const handlers = this.listeners.get(event) || new Set();
    handlers.add(handler);
    this.listeners.set(event, handlers);
  }

  emit(event, payload) {
    for (const handler of this.listeners.get(event) || []) Promise.resolve(handler(payload)).catch(() => {});
  }

  send(method, params = {}, timeoutMs = 5000) {
    if (this.socket?.readyState !== WebSocket.OPEN) return Promise.reject(new Error("DevTools WebSocket is not open"));
    const id = ++this.counter;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression, awaitPromise = true) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: false,
    }, 8000);
    if (result?.exceptionDetails) throw new Error(result.exceptionDetails.text || "Renderer evaluation failed");
    return result?.result?.value;
  }

  close() {
    try { this.socket?.close(); } catch {}
  }
}

async function rendererPayload() {
  const [source, css] = await Promise.all([
    fs.readFile(path.join(here, "renderer.js"), "utf8"),
    fs.readFile(path.join(here, "native-dock.css"), "utf8"),
  ]);
  return source
    .replace("__CND_CSS_JSON__", JSON.stringify(css))
    .replace("__CND_VERSION_JSON__", JSON.stringify(VERSION));
}

async function sendUsage(session, bindingPayload) {
  let request;
  try { request = JSON.parse(bindingPayload); } catch { return; }
  if (request?.action !== "usage" || typeof request.threadId !== "string") return;
  let metrics;
  try {
    metrics = await readUsage(request.threadId);
  } catch (error) {
    metrics = { available: false, threadId: request.threadId, reason: error.message };
  }
  await session.evaluate(`window.__CODEX_NATIVE_DOCK_USAGE_UPDATE__?.(${JSON.stringify(metrics)})`).catch(() => {});
}

async function connectTarget(target, payload) {
  const session = await new CdpSession(target.socketUrl).open();
  await session.send("Runtime.enable");
  await session.send("Page.enable");
  await session.send("Runtime.addBinding", { name: "__codexNativeDockUsageRequest" }).catch((error) => {
    if (!/already exists/i.test(error.message)) throw error;
  });
  session.on("Runtime.bindingCalled", ({ name, payload: bindingPayload }) => {
    if (name === "__codexNativeDockUsageRequest") return sendUsage(session, bindingPayload);
  });
  let installed = false;
  let reinjecting = false;
  session.on("Page.loadEventFired", async () => {
    if (!installed || reinjecting) return;
    reinjecting = true;
    try { await session.evaluate(payload); } catch {}
    reinjecting = false;
  });
  await session.evaluate(payload);
  installed = true;
  return session;
}

async function evaluateTarget(target, expression) {
  const session = await new CdpSession(target.socketUrl).open();
  try {
    await session.send("Runtime.enable");
    return await session.evaluate(expression);
  } finally {
    session.close();
  }
}

const REMOVE_EXPRESSION = `(() => {
  window.__CODEX_NATIVE_DOCK_STATE__?.cleanup?.();
  document.getElementById("codex-native-dock-root")?.remove();
  document.getElementById("codex-native-dock-style")?.remove();
  document.documentElement.classList.remove("codex-native-dock-focus");
  return { removed: true };
})()`;

const VERIFY_EXPRESSION = `(() => {
  const root = document.getElementById("codex-native-dock-root");
  const style = document.getElementById("codex-native-dock-style");
  const dock = root?.querySelector(".cnd-tools");
  const usage = root?.querySelector(".cnd-usage");
  const composer = document.querySelector(".composer-surface-chrome");
  const visible = element => !!element && getComputedStyle(element).display !== "none" && element.getBoundingClientRect().width > 0;
  const composerRect = composer?.getBoundingClientRect();
  const usageRect = visible(usage) ? usage.getBoundingClientRect() : null;
  const alignment = composerRect && usageRect ? {
    left: Math.abs(composerRect.left - usageRect.left),
    right: Math.abs(composerRect.right - usageRect.right),
    gap: Math.abs(composerRect.bottom + 1 - usageRect.top),
  } : null;
  const aligned = !alignment || (alignment.left <= 1.25 && alignment.right <= 1.25 && alignment.gap <= 1.25);
  return {
    pass: !!root && !!style && visible(dock) && aligned,
    version: root?.dataset?.version || null,
    rootCount: document.querySelectorAll("#codex-native-dock-root").length,
    styleCount: document.querySelectorAll("#codex-native-dock-style").length,
    dockVisible: visible(dock),
    usageVisible: visible(usage),
    alignment,
    aligned,
  };
})()`;

async function listTargets(options) {
  await validateBrowser(options.port, options.browserId);
  return selectTargets(await fetchJson(options.port, "/json/list"), options.port);
}

async function runOneShot(options, operation) {
  const targets = await listTargets(options);
  if (targets.length === 0) throw new Error("No Codex page target was found");
  const output = [];
  for (const target of targets) output.push({ target: target.id, result: await operation(target) });
  return output;
}

async function runWatch(options) {
  const payload = await rendererPayload();
  const sessions = new Map();
  let stopped = false;
  const stop = () => {
    stopped = true;
    for (const session of sessions.values()) session.close();
    sessions.clear();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  console.log(`Codex Native Dock ${VERSION} watching 127.0.0.1:${options.port}`);
  while (!stopped) {
    try {
      const targets = await listTargets(options);
      const current = new Set(targets.map((target) => target.id));
      for (const [id, session] of sessions) {
        if (!current.has(id)) { session.close(); sessions.delete(id); }
      }
      for (const target of targets) {
        if (sessions.has(target.id)) continue;
        try {
          const session = await connectTarget(target, payload);
          sessions.set(target.id, session);
          session.on("close", () => sessions.delete(target.id));
          console.log(`Injected ${target.url} (${target.id})`);
        } catch (error) {
          console.error(`Injection failed for ${target.id}: ${error.message}`);
        }
      }
    } catch (error) {
      console.error(`Watch cycle failed: ${error.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

function runSelfTest(port) {
  const page = `ws://127.0.0.1:${port}/devtools/page/page-1`;
  const browser = `ws://127.0.0.1:${port}/devtools/browser/browser-1`;
  if (validateSocketUrl(page, port, "page", "page-1").identity !== "page-1") throw new Error("Page validation failed");
  if (validateSocketUrl(browser, port, "browser").identity !== "browser-1") throw new Error("Browser validation failed");
  for (const invalid of [
    `ws://0.0.0.0:${port}/devtools/page/page-1`,
    `ws://127.0.0.1:${port}/devtools/browser/page-1`,
    `ws://127.0.0.1:${port + 1}/devtools/page/page-1`,
    `wss://127.0.0.1:${port}/devtools/page/page-1`,
  ]) {
    let rejected = false;
    try { validateSocketUrl(invalid, port, "page", "page-1"); } catch { rejected = true; }
    if (!rejected) throw new Error(`Unsafe endpoint accepted: ${invalid}`);
  }
  const selected = selectTargets([
    { id: "page-1", type: "page", url: "app://-/index.html", webSocketDebuggerUrl: page },
    { id: "browser-1", type: "page", url: "https://example.com", webSocketDebuggerUrl: page },
  ], port);
  if (selected.length !== 1) throw new Error("Target filtering failed");
  console.log("Self-test PASS");
}

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (options.mode === "help") return printHelp();
  if (options.mode === "self-test") return runSelfTest(options.port);
  if (options.mode === "watch") return runWatch(options);
  if (options.mode === "once") {
    const payload = await rendererPayload();
    const output = await runOneShot(options, async (target) => {
      const session = await connectTarget(target, payload);
      session.close();
      return { installed: true, version: VERSION };
    });
    console.log(JSON.stringify(output, null, 2));
    return;
  }
  if (options.mode === "remove") {
    console.log(JSON.stringify(await runOneShot(options, (target) => evaluateTarget(target, REMOVE_EXPRESSION)), null, 2));
    return;
  }
  if (options.mode === "verify") {
    const output = await runOneShot(options, (target) => evaluateTarget(target, VERIFY_EXPRESSION));
    console.log(JSON.stringify(output, null, 2));
    if (output.some(({ result }) => !result?.pass)) process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`Codex Native Dock: ${error.message}`);
  process.exitCode = 1;
});
