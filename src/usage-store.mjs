import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const THREAD_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_SCAN_ENTRIES = 12000;
const MAX_TAIL_BYTES = 1024 * 1024;
const MAX_INCREMENT_BYTES = 2 * 1024 * 1024;
const pathCache = new Map();
const usageCache = new Map();

const finite = (value) => Number.isFinite(Number(value)) ? Number(value) : null;

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function locateSession(threadId, codexHome) {
  if (!THREAD_ID.test(threadId)) throw new Error("Invalid task identity");
  const cached = pathCache.get(threadId);
  if (cached && await exists(cached)) return cached;

  const stack = [path.join(codexHome, "sessions")];
  const matches = [];
  let inspected = 0;
  while (stack.length > 0 && inspected < MAX_SCAN_ENTRIES) {
    const directory = stack.pop();
    let entries;
    try {
      entries = await fs.readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      inspected += 1;
      if (inspected > MAX_SCAN_ENTRIES) break;
      if (entry.isSymbolicLink()) continue;
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) stack.push(candidate);
      if (entry.isFile() && entry.name.endsWith(".jsonl") && entry.name.includes(threadId)) {
        const stat = await fs.stat(candidate);
        matches.push({ filePath: candidate, modifiedAt: stat.mtimeMs });
      }
    }
  }
  matches.sort((left, right) => right.modifiedAt - left.modifiedAt);
  if (matches.length === 0) throw new Error("Usage data is not available yet");
  pathCache.set(threadId, matches[0].filePath);
  return matches[0].filePath;
}

function normalizeRateWindow(window) {
  if (!window || typeof window !== "object") return null;
  const usedPercent = finite(window.used_percent);
  if (usedPercent === null) return null;
  const used = Math.min(100, Math.max(0, usedPercent));
  return {
    usedPercent: used,
    remainingPercent: 100 - used,
    windowMinutes: finite(window.window_minutes),
    resetsAt: finite(window.resets_at),
  };
}

function consumeLine(state, line) {
  if (!line.includes("token_count")) return;
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    return;
  }
  const payload = record?.payload;
  if (payload?.type !== "token_count") return;

  const last = payload.info?.last_token_usage;
  const usedTokens = finite(last?.total_tokens);
  const windowTokens = finite(payload.info?.model_context_window);
  if (usedTokens !== null || windowTokens !== null) {
    state.context = {
      usedTokens,
      windowTokens,
      remainingTokens: usedTokens !== null && windowTokens !== null
        ? Math.max(0, windowTokens - usedTokens)
        : null,
    };
  }
  const primary = normalizeRateWindow(payload.rate_limits?.primary);
  if (primary) state.primary = primary;
  state.updatedAt = record.timestamp || state.updatedAt || null;
}

export async function readUsage(threadId, options = {}) {
  const codexHome = options.codexHome || process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  const sessionPath = await locateSession(threadId, codexHome);
  let state = usageCache.get(threadId);
  if (!state || state.filePath !== sessionPath) {
    state = {
      filePath: sessionPath,
      offset: 0,
      remainder: "",
      context: null,
      primary: null,
      updatedAt: null,
    };
    usageCache.set(threadId, state);
  }

  const handle = await fs.open(sessionPath, "r");
  try {
    const stat = await handle.stat();
    if (stat.size < state.offset) {
      state.offset = 0;
      state.remainder = "";
      state.context = null;
      state.primary = null;
      state.updatedAt = null;
    }

    const firstRead = state.offset === 0;
    const unread = stat.size - state.offset;
    const skipLargeIncrement = !firstRead && unread > MAX_INCREMENT_BYTES;
    const readStart = firstRead || skipLargeIncrement
      ? Math.max(0, stat.size - MAX_TAIL_BYTES)
      : state.offset;
    const readLength = Math.max(0, stat.size - readStart);
    if (readLength > 0) {
      const buffer = Buffer.alloc(readLength);
      await handle.read(buffer, 0, readLength, readStart);
      let text = (firstRead || skipLargeIncrement ? "" : state.remainder) + buffer.toString("utf8");
      if ((firstRead || skipLargeIncrement) && readStart > 0) {
        const firstNewline = text.indexOf("\n");
        text = firstNewline >= 0 ? text.slice(firstNewline + 1) : "";
      }
      const lines = text.split(/\r?\n/);
      state.remainder = lines.pop() || "";
      for (const line of lines) consumeLine(state, line);
      state.offset = stat.size;
    }
  } finally {
    await handle.close();
  }

  if (!state.context && !state.primary) {
    return { available: false, threadId, reason: "Usage data is not available yet" };
  }
  return {
    available: true,
    threadId,
    updatedAt: state.updatedAt,
    context: state.context,
    rateLimits: { primary: state.primary },
  };
}

export function clearUsageCaches() {
  pathCache.clear();
  usageCache.clear();
}
