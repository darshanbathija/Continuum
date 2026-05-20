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
 */
async function loadSDK() {
  try {
    const sdk = await import("@openai/codex-sdk");
    return sdk;
  } catch (err) {
    if (err && err.code === "ERR_MODULE_NOT_FOUND") return null;
    // Other import errors (corrupt install, version mismatch) — log
    // but still treat as not-provisioned so the toggle reverts cleanly.
    emit({
      type: "log",
      level: "warn",
      msg: `Codex SDK import failed: ${err?.message ?? String(err)}`,
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
  const threadOptions = {
    workingDirectory: cmd.workingDirectory,
    skipGitRepoCheck: cmd.skipGitRepoCheck ?? false,
    model: cmd.model,
    sandboxMode: cmd.sandboxMode,
    modelReasoningEffort: cmd.modelReasoningEffort,
    approvalPolicy: cmd.approvalPolicy,
    additionalDirectories: cmd.additionalDirectories,
  };
  // Drop undefined keys so we don't override CLI defaults.
  for (const k of Object.keys(threadOptions)) {
    if (threadOptions[k] === undefined) delete threadOptions[k];
  }

  const thread = cmd.op === "resume" && cmd.threadId
    ? codex.resumeThread(cmd.threadId, threadOptions)
    : codex.startThread(threadOptions);

  const prompt = cmd.prompt ?? "";
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
  const codex = new SDK.Codex();
  const threadOptions = {
    workingDirectory: cmd.workingDirectory,
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

  const turn = await thread.run(cmd.prompt ?? "", {});
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
  if (SDK) {
    emit({ type: "ready", version: SDK_VERSION });
  } else {
    emit({ type: "ready", version: SKELETON_VERSION });
  }

  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let firstLine = true;
  let agent = null;

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
