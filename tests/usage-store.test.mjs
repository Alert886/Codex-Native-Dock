import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { clearUsageCaches, readUsage } from "../src/usage-store.mjs";

const threadId = "12345678-1234-4234-8234-123456789abc";
const record = (usedPercent, usedTokens = 1200) => JSON.stringify({
  timestamp: "2026-07-18T12:00:00Z",
  payload: {
    type: "token_count",
    info: { last_token_usage: { total_tokens: usedTokens }, model_context_window: 258400 },
    rate_limits: { primary: { used_percent: usedPercent, window_minutes: 10080, resets_at: 1784908800 } },
  },
});

test("reads the latest local quota and incrementally updates it", async (context) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "cnd-usage-"));
  context.after(() => fs.rm(home, { recursive: true, force: true }));
  const directory = path.join(home, "sessions", "2026", "07", "18");
  await fs.mkdir(directory, { recursive: true });
  const file = path.join(directory, `rollout-${threadId}.jsonl`);
  await fs.writeFile(file, `${record(37, 1200)}\n`);
  clearUsageCaches();
  const first = await readUsage(threadId, { codexHome: home });
  assert.equal(first.available, true);
  assert.equal(first.rateLimits.primary.remainingPercent, 63);
  assert.equal(first.context.usedTokens, 1200);

  await fs.appendFile(file, `${record(38, 2400)}\n`);
  const second = await readUsage(threadId, { codexHome: home });
  assert.equal(second.rateLimits.primary.remainingPercent, 62);
  assert.equal(second.context.usedTokens, 2400);
});

test("does not invent 100 percent when usage is missing", async (context) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "cnd-empty-"));
  context.after(() => fs.rm(home, { recursive: true, force: true }));
  const directory = path.join(home, "sessions");
  await fs.mkdir(directory, { recursive: true });
  await fs.writeFile(path.join(directory, `rollout-${threadId}.jsonl`), '{"payload":{"type":"event"}}\n');
  clearUsageCaches();
  const result = await readUsage(threadId, { codexHome: home });
  assert.equal(result.available, false);
  assert.equal(result.rateLimits, undefined);
});

test("rejects an invalid task identity before scanning", async () => {
  clearUsageCaches();
  await assert.rejects(() => readUsage("../../secrets"), /Invalid task identity/);
});
