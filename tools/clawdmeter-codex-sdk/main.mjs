#!/usr/bin/env node
// Sidecar dispatcher for Clawdmeter Codex SDK mode (v0.7.1+).
//
// Self-bootstrapping: tries to `import("@openai/codex-sdk")` at startup. If
// the SDK is installed, emits `{type:"ready",version:"0.7.1-sdk"}` and
// dispatches real subcommands. If not installed (skeleton state — pre
// v0.7.1 provisioning), emits `{type:"ready",version:"0.7.1-skeleton"}`
// and falls back to the `sdk_not_provisioned` error path so the
// CodexSDKManager's revert flow exercises end-to-end.
//
// Subcommands:
//   probe    — acknowledge ready, then exit on first op (smoke test
//              for CodexSDKManager toggle).
//   observer — long-running. Accepts subscribe/stop ops over stdin
//              JSON-lines; for each subscribe runs `thread.runStreamed`
//              and emits every event back as JSON-lines.
//   resume   — one-shot. `codex.resumeThread(threadId).run(prompt)` and
//              emit the completed Turn (text + usage). Used by the X1
//              cross-Apple compose-draft flow for iOS→Mac handoff.
//
// **Auth contract** (verified against ~/.codex/auth.json): when the
// user runs `codex login` with the ChatGPT plan, auth.json sets
// `auth_mode: "chatgpt"` and stores OAuth tokens. The SDK inherits
// these automatically — no `apiKey` parameter needed in the Codex
// constructor. Usage draws against the ChatGPT subscription quota.

import { createInterface } from "node:readline";
import { realpathSync } from "node:fs";
import { normalize, resolve as resolvePath } from "node:path";
import { homedir } from "node:os";

// Audit P1 fix: workingDirectory and prompt come in over stdin from the
// Mac Swift app. We trust the harness, but defense-in-depth: validate
// the cwd is under $HOME and cap prompt length so a broken caller (or
// stuck stream) can't OOM us or feed a path that escapes the user's
// home onto an SDK call that interprets it as a shell cwd.
const MAX_PROMPT_BYTES = 256 * 1024;            // 256 KB
const MAX_LINE_BYTES = 1 * 1024 * 1024;         // 1 MB per stdin line

function safeWorkingDirectory(raw) {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== "string" || raw.length === 0 || raw.includes("\0")) {
    throw new Error("workingDirectory must be a non-empty string without null bytes");
  }
  if (!raw.startsWith("/")) {
    throw new Error("workingDirectory must be absolute");
  }
  let canonical;
  try { canonical = realpathSync(raw); }
  catch { canonical = resolvePath(raw); }
  const normalized = normalize(canonical);
  const home = homedir();
  if (!normalized.startsWith(home + "/") && normalized !== home) {
    throw new Error(`workingDirectory must be under $HOME (got ${normalized})`);
  }
  return normalized;
}

function safePrompt(raw) {
  if (raw === undefined || raw === null) return "";
  if (typeof raw !== "string") {
    throw new Error("prompt must be a string");
  }
  if (Buffer.byteLength(raw, "utf8") > MAX_PROMPT_BYTES) {
    throw new Error(`prompt exceeds ${MAX_PROMPT_BYTES} byte cap`);
  }
  return raw;
}

function requireProviderSpendAllowed(agent) {
  if (process.env.CLAWDMETER_ALLOW_PROVIDER_SPEND === "1") return;
  throw new Error(
    `${agent} would send a live Codex provider prompt; set CLAWDMETER_ALLOW_PROVIDER_SPEND=1 to run it`
  );
}

const SKELETON_VERSION = "0.7.1-skeleton";
const SDK_VERSION = "0.7.1-sdk";

/** Write one JSON-line to stdout. */
function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

/**
 * Attempt to import the Codex SDK. Returns the module object on
 * success, or null when the dep isn't installed. Caller falls back
 * to skeleton mode on null.
 *
 * Audit P2 fix: race the import against a hard 5s deadline so a
 * corrupted module / slow disk can't pin the probe indefinitely
 * (which causes the Swift app to spawn another sidecar → pileup).
 */
async function loadSDK() {
  const importOnce = async () => {
    try {
      return await import("@openai/codex-sdk");
    } catch (err) {
      if (err && err.code === "ERR_MODULE_NOT_FOUND") return null;
      emit({
        type: "log",
        level: "warn",
        msg: `Codex SDK import failed: ${err?.message ?? String(err)}`,
      });
      return null;
    }
  };
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("SDK import timed out after 5s")), 5_000).unref()
  );
  try {
    return await Promise.race([importOnce(), timeout]);
  } catch (err) {
    emit({
      type: "log",
      level: "warn",
      msg: `Codex SDK import deadline: ${err?.message ?? String(err)}`,
    });
    return null;
  }
}

/**
 * Long-running observer mode. Manages per-subscription AbortControllers
 * so the daemon can cancel an in-flight stream when the user closes
 * the session pane.
 */
async function runObserver(SDK, rl) {
  const codex = new SDK.Codex();
  /** @type {Map<string, AbortController>} */
  const subscriptions = new Map();
  emit({ type: "observer_ready" });

  for await (const raw of rl) {
    const line = raw.trim();
    if (!line) continue;
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch (err) {
      emit({ type: "error", msg: `bad JSON: ${err.message}`, raw: line.slice(0, 200) });
      continue;
    }

    switch (cmd.op) {
      case "start":
      case "resume": {
        const subId = cmd.subscriptionId ?? `sub-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
        // Spawn the subscription asynchronously so multiple streams
        // can run concurrently. Each gets its own AbortController.
        const controller = new AbortController();
        subscriptions.set(subId, controller);
        streamThread(codex, cmd, subId, controller.signal).catch((err) => {
          emit({
            type: "stream_error",
            subscriptionId: subId,
            msg: err?.message ?? String(err),
          });
        }).finally(() => {
          subscriptions.delete(subId);
        });
        emit({ type: "stream_started", subscriptionId: subId, op: cmd.op });
        break;
      }
      case "stop": {
        const ctl = subscriptions.get(cmd.subscriptionId);
        if (ctl) {
          ctl.abort();
          subscriptions.delete(cmd.subscriptionId);
          emit({ type: "stream_stopped", subscriptionId: cmd.subscriptionId });
        } else {
          emit({ type: "error", msg: `unknown subscriptionId: ${cmd.subscriptionId}` });
        }
        break;
      }
      case "shutdown": {
        for (const [, ctl] of subscriptions) ctl.abort();
        subscriptions.clear();
        emit({ type: "shutdown_ack" });
        return;
      }
      default:
        emit({ type: "error", msg: `unknown op: ${cmd.op ?? "(none)"}` });
    }
  }
}

/**
 * Runs one streamed turn against a (new or resumed) Codex thread and
 * pipes every event back to stdout under the given subscriptionId.
 * Cancellable via the AbortSignal.
 */
async function streamThread(codex, cmd, subscriptionId, signal) {
  requireProviderSpendAllowed("codex streamThread");
  const threadOptions = {
    workingDirectory: safeWorkingDirectory(cmd.workingDirectory),
    skipGitRepoCheck: cmd.skipGitRepoCheck ?? false,
    model: cmd.model,
    sandboxMode: cmd.sandboxMode,
    modelReasoningEffort: cmd.modelReasoningEffort,
    approvalPolicy: cmd.approvalPolicy,
    additionalDirectories: cmd.additionalDirectories,
    // v0.23 (Chat V2 — T7 Deep Research): the Swift relay sets
    // `tools: ["web_search"]` when the session has deepResearch=true so
    // the Codex SDK enables web search alongside the thread's other
    // capabilities. The SDK reads this off the threadOptions object;
    // we just pass it through. Undefined / empty arrays are filtered
    // out below so existing chat behavior is unchanged for non-DR
    // sessions.
    tools: cmd.tools,
  };
  // Drop undefined keys so we don't override CLI defaults.
  for (const k of Object.keys(threadOptions)) {
    if (threadOptions[k] === undefined) delete threadOptions[k];
  }

  const thread = cmd.op === "resume" && cmd.threadId
    ? codex.resumeThread(cmd.threadId, threadOptions)
    : codex.startThread(threadOptions);

  // PR #69 audit P1: validate prompt shape + cap size before the SDK
  // sees it (defense-in-depth against runaway callers).
  // v0.23 (Chat V2 T7) Deep Research: prepend the contract header to
  // the user prompt because the Codex SDK has no separate
  // system-instruction field. The header is injected as the front of
  // the first user turn — the SDK retains it in conversation memory,
  // so subsequent turns of the same thread don't re-prepend.
  const safeCore = safePrompt(cmd.prompt);
  const prompt = cmd.deepResearchHeader
    ? `${cmd.deepResearchHeader}\n\nUSER QUESTION:\n${safeCore}`
    : safeCore;
  const turn = await thread.runStreamed(prompt, { signal });
  for await (const event of turn.events) {
    emit({
      type: "stream_event",
      subscriptionId,
      threadId: thread.id ?? null,
      event,
    });
    if (event.type === "turn.completed" || event.type === "turn.failed" || event.type === "error") {
      emit({
        type: "stream_done",
        subscriptionId,
        threadId: thread.id ?? null,
        terminator: event.type,
      });
      return;
    }
  }
}

/**
 * One-shot resume: open the thread, run the prompt to completion (NOT
 * streamed), emit the full Turn. Used by iOS→Mac compose-draft handoff
 * where iOS already has a threadId and wants to push a new prompt onto
 * it without keeping a long-running stream open.
 */
async function runResume(SDK, cmd) {
  requireProviderSpendAllowed("codex resume");
  const codex = new SDK.Codex();
  const threadOptions = {
    workingDirectory: safeWorkingDirectory(cmd.workingDirectory),
    skipGitRepoCheck: cmd.skipGitRepoCheck ?? false,
    model: cmd.model,
    sandboxMode: cmd.sandboxMode,
    modelReasoningEffort: cmd.modelReasoningEffort,
    approvalPolicy: cmd.approvalPolicy,
  };
  for (const k of Object.keys(threadOptions)) {
    if (threadOptions[k] === undefined) delete threadOptions[k];
  }

  if (!cmd.threadId) {
    emit({ type: "error", msg: "resume requires threadId" });
    return;
  }
  const thread = SDK.Codex
    ? new SDK.Codex().resumeThread(cmd.threadId, threadOptions)
    : codex.resumeThread(cmd.threadId, threadOptions);

  const turn = await thread.run(safePrompt(cmd.prompt), {});
  emit({
    type: "resume_result",
    threadId: thread.id ?? cmd.threadId,
    finalResponse: turn.finalResponse,
    items: turn.items,
    usage: turn.usage,
  });
}

async function main() {
  const SDK = await loadSDK();
  // Audit P2 fix: emit a single consistent `ready` schema for both
  // modes so the Mac side always parses the same shape. The old
  // skeleton emitted a different `type` in some paths and a `result`
  // payload, which the app misread as a successful probe.
  emit({
    type: "ready",
    version: SDK ? SDK_VERSION : SKELETON_VERSION,
    sdk_available: !!SDK,
    skeleton: !SDK,
  });

  // Audit P1 fix: drop `crlfDelay: Infinity` (which allowed unbounded
  // line accumulation) and enforce a per-line byte cap so a stuck
  // sender can't OOM the sidecar.
  const rl = createInterface({ input: process.stdin });
  let firstLine = true;
  let agent = null;

  // Per-line guard: readline doesn't expose a max-line-length option,
  // so we watch the stdin chunk stream and bail if we go too long.
  let pendingLineBytes = 0;
  process.stdin.on("data", (chunk) => {
    if (chunk.includes(0x0a)) {
      pendingLineBytes = 0;
    } else {
      pendingLineBytes += chunk.length;
      if (pendingLineBytes > MAX_LINE_BYTES) {
        emit({ type: "error", msg: `stdin line exceeded ${MAX_LINE_BYTES} bytes — aborting` });
        process.exit(2);
      }
    }
  });

  for await (const raw of rl) {
    const line = raw.trim();
    if (!line) continue;
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch (err) {
      emit({ type: "error", msg: `bad JSON: ${err.message}`, raw: line.slice(0, 200) });
      if (firstLine) process.exit(1);
      continue;
    }

    if (firstLine) {
      firstLine = false;
      agent = cmd.agent ?? "(unspecified)";

      if (!SDK) {
        emit({
          type: "error",
          code: "sdk_not_provisioned",
          msg: "Codex SDK not installed — run `npm install @openai/codex-sdk` in the sidecar dir. CodexSDKManager handles this on toggle ON.",
          agent,
        });
        // Stay in the loop so subsequent ops also get an explicit
        // sdk_not_provisioned reply — matches v0.7.0 skeleton behavior.
        continue;
      }

      // Real-impl dispatch.
      try {
        if (agent === "probe") {
          emit({ type: "probe_ok", sdkVersion: SDK_VERSION });
          return;
        }
        if (agent === "observer") {
          await runObserver(SDK, rl);
          return;
        }
        if (agent === "resume") {
          await runResume(SDK, cmd);
          return;
        }
        emit({ type: "error", msg: `unknown agent: ${agent}` });
        return;
      } catch (err) {
        emit({ type: "error", msg: `agent ${agent} failed: ${err?.message ?? String(err)}` });
        return;
      }
    }

    // Subsequent lines in skeleton mode: emit sdk_not_provisioned with
    // the echoed op so callers can correlate. (SDK mode never reaches
    // here — runObserver / runResume / runProbe all return early.)
    emit({
      type: "error",
      code: "sdk_not_provisioned",
      msg: "Skeleton — full impl requires `npm install @openai/codex-sdk`.",
      echoed_op: cmd.op ?? null,
    });
  }
}

main().catch((err) => {
  emit({ type: "error", msg: `fatal: ${err?.message ?? String(err)}` });
  process.exit(2);
});
