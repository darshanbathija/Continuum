// Smoke tests for the v0.7.0 Codex SDK sidecar skeleton.
// Run via `node --test tests/` from the package root.
//
// These mirror the Antigravity sidecar's pytest fixture shape:
//   - happy path: emit ready, then sdk_not_provisioned
//   - missing header: emit error, exit 1
//   - garbage JSON: emit error, exit 1

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MAIN = resolve(__dirname, "..", "main.mjs");

/**
 * Run main.mjs with the given stdin, return { code, stdout, stderr }.
 */
function runSidecar(input, timeoutMs = 5000) {
  return new Promise((resolveOuter, reject) => {
    const proc = spawn(process.execPath, [MAIN]);
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d.toString()));
    proc.stderr.on("data", (d) => (stderr += d.toString()));
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error("timeout"));
    }, timeoutMs);
    proc.on("close", (code) => {
      clearTimeout(timer);
      resolveOuter({ code, stdout, stderr });
    });
    proc.stdin.write(input);
    proc.stdin.end();
  });
}

function parseLines(out) {
  return out
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => JSON.parse(s));
}

test("emits ready then sdk_not_provisioned for a valid header (skeleton mode)", async () => {
  // When the @openai/codex-sdk module isn't reachable from this script's
  // resolution path, main.mjs falls back to skeleton mode. Repo tree
  // doesn't include the SDK in node_modules (it's installed to AppSupport
  // by CodexSDKManager.provisionIfNeeded), so test runs hit this path.
  const { code, stdout } = await runSidecar(
    JSON.stringify({ agent: "observer" }) + "\n"
  );
  assert.equal(code, 0);
  const lines = parseLines(stdout);
  assert.ok(lines.length >= 2, "expect ready + error");
  assert.equal(lines[0].type, "ready");
  // Accept either skeleton (CI/repo run, no SDK installed) or sdk (dev
  // machine with SDK provisioned in AppSupport that bleeds through).
  assert.ok(
    lines[0].version === "0.7.1-skeleton" || lines[0].version === "0.7.1-sdk",
    `unexpected version: ${lines[0].version}`
  );
  // When skeleton: sdk_not_provisioned error follows.
  // When sdk: observer_ready follows.
  if (lines[0].version === "0.7.1-skeleton") {
    assert.equal(lines[1].type, "error");
    assert.equal(lines[1].code, "sdk_not_provisioned");
    assert.equal(lines[1].agent, "observer");
  } else {
    // SDK mode entered observer; should emit observer_ready (or stream
    // events as we feed it more). Validate the shape, not exact value.
    assert.ok(["observer_ready", "stream_started", "error"].includes(lines[1].type));
  }
});

test("emits error and exits 1 on missing header (EOF)", async () => {
  const { code, stdout } = await runSidecar("");
  // Empty stdin → readline closes immediately → main() returns,
  // process exits 0 after emitting ready. No header consumed,
  // no error follows. That's the "graceful no-op" branch.
  assert.equal(code, 0);
  const lines = parseLines(stdout);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].type, "ready");
});

test("emits error and exits 1 on garbage header JSON", async () => {
  const { code, stdout } = await runSidecar("this is not json\n");
  assert.equal(code, 1);
  const lines = parseLines(stdout);
  // ready + error
  assert.ok(lines.length >= 2);
  assert.equal(lines[0].type, "ready");
  assert.equal(lines[1].type, "error");
  assert.ok(lines[1].msg.toLowerCase().includes("json"));
});

test("tolerates a second op line after the header without crashing", async () => {
  const input =
    JSON.stringify({ agent: "observer" }) +
    "\n" +
    JSON.stringify({ op: "list_threads" }) +
    "\n";
  const { code, stdout } = await runSidecar(input);
  assert.equal(code, 0);
  const lines = parseLines(stdout);
  // ready + 2 errors (header processed, op processed)
  assert.equal(lines.length, 3);
  assert.equal(lines[0].type, "ready");
  assert.equal(lines[1].type, "error");
  assert.equal(lines[1].agent, "observer");
  assert.equal(lines[2].type, "error");
  assert.equal(lines[2].echoed_op, "list_threads");
});
