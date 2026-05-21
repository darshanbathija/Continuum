#!/usr/bin/env node
// clawdmeter-bridge-host — loopback HTTP sidecar that mints
// desktop-import-tokens for the Clawdmeter Mac app's Code→Design handoff.
//
// Architecture:
//   1. On startup, generate a 32-byte HMAC secret.
//   2. Register the secret with the Open Design daemon via its sidecar IPC
//      protocol (REGISTER_DESKTOP_AUTH message — see Open Design's
//      apps/daemon/src/sidecar/server.ts:146).
//   3. Bind a loopback-only HTTP listener (probed free port starting at 27457).
//   4. Endpoints:
//        POST /sign-import-token  { baseDir, ttlMs? } → { token, exp, nonce }
//        POST /import-folder      { baseDir }         → { projectId }   (proxies to Open Design)
//        GET  /health                                  → { ok, daemonReady, hasSecret }
//
// Lifecycle: spawned by OpenDesignDaemonManager AFTER the daemon reports
// `ready`; dies with daemon (same process group). Restart-on-crash supervised
// by OpenDesignDaemonManager.
//
// Required env:
//   OD_DAEMON_PORT       — port the Open Design daemon is bound to
//   OD_DATA_DIR          — Open Design data dir (for IPC path resolution)
//   CLAWDMETER_BRIDGE_PORT — preferred bridge port (probe starts here; default 27457)

import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DESKTOP_IMPORT_TOKEN_SEP = "~";
const DEFAULT_TTL_MS = 60_000;
const DEFAULT_BRIDGE_PORT = parseInt(process.env.CLAWDMETER_BRIDGE_PORT || "27457", 10);
const DAEMON_PORT = parseInt(process.env.OD_DAEMON_PORT || "", 10);
const DATA_DIR = process.env.OD_DATA_DIR;

if (!Number.isFinite(DAEMON_PORT) || DAEMON_PORT <= 0) {
  console.error("[bridge] OD_DAEMON_PORT must be set to a positive integer");
  process.exit(2);
}

// ────────────────────────────────────────────────────────────────────
// HMAC secret + IPC handshake
// ────────────────────────────────────────────────────────────────────

const HMAC_SECRET = randomBytes(32);

/**
 * Register the HMAC secret with the running daemon via its sidecar IPC.
 *
 * Open Design's daemon-sidecar protocol (apps/daemon/src/sidecar/server.ts)
 * uses @open-design/sidecar's JsonIpcServer/Client over a Unix socket at a
 * derived path. The wire message kind is REGISTER_DESKTOP_AUTH with a base64
 * secret payload.
 *
 * TODO(t8-integration): bundle and import @open-design/sidecar from the
 * sibling apps/daemon/node_modules so we can call requestJsonIpc({kind:
 * SIDECAR_MESSAGES.REGISTER_DESKTOP_AUTH, input: {secret: base64}}) directly
 * instead of speaking the raw protocol. Integration test must verify:
 *   - daemon's `desktopAuthGateActive` flips to true after registration
 *   - subsequent /api/import/folder calls with our signed token succeed
 *   - daemon restart (we re-register on bridge restart) works idempotently
 *
 * Until that ships, this function returns ok=false and the /sign-import-token
 * route returns a token Open Design will reject — Code→Design handoff is
 * inert until completed. Loopback Mac WebView (which doesn't need this) works.
 */
async function registerWithDaemon() {
  try {
    const protoModule = await tryImportSidecarProto();
    const sidecarModule = await tryImportSidecar();
    if (!protoModule || !sidecarModule) {
      return { ok: false, reason: "sidecar packages not bundled — see TODO above" };
    }
    const { SIDECAR_MESSAGES } = protoModule;
    const { requestJsonIpc, resolveAppIpcPath } = sidecarModule;
    const ipcPath = resolveAppIpcPath({ dataDir: DATA_DIR });
    const response = await requestJsonIpc(ipcPath, {
      kind: SIDECAR_MESSAGES.REGISTER_DESKTOP_AUTH,
      input: { secret: HMAC_SECRET.toString("base64") },
    });
    return { ok: response?.ok === true, reason: response?.error?.message };
  } catch (err) {
    return { ok: false, reason: `IPC registration failed: ${err.message}` };
  }
}

async function tryImportSidecarProto() {
  // The bundled daemon's node_modules has @open-design/sidecar-proto next to
  // us. Resolve via the daemon's package layout.
  const here = dirname(fileURLToPath(import.meta.url));
  const candidate = join(here, "..", "apps", "daemon", "node_modules", "@open-design", "sidecar-proto", "dist", "index.js");
  if (!existsSync(candidate)) return null;
  return await import(candidate);
}

async function tryImportSidecar() {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidate = join(here, "..", "apps", "daemon", "node_modules", "@open-design", "sidecar", "dist", "index.js");
  if (!existsSync(candidate)) return null;
  return await import(candidate);
}

// ────────────────────────────────────────────────────────────────────
// Token signing — mirrors Open Design's signDesktopImportToken
// (apps/daemon/src/desktop-auth.ts:48). Kept in lockstep with that
// implementation so the daemon's verifier accepts our tokens.
// ────────────────────────────────────────────────────────────────────

function signDesktopImportToken(baseDir, { nonce, expISO }) {
  const signature = createHmac("sha256", HMAC_SECRET)
    .update(`${baseDir}\n${nonce}\n${expISO}`)
    .digest("base64url");
  return [nonce, expISO, signature].join(DESKTOP_IMPORT_TOKEN_SEP);
}

function mintImportToken(baseDir, ttlMs) {
  const nonce = randomBytes(16).toString("base64url");
  const expISO = new Date(Date.now() + ttlMs).toISOString();
  const token = signDesktopImportToken(baseDir, { nonce, expISO });
  return { token, exp: expISO, nonce };
}

// ────────────────────────────────────────────────────────────────────
// HTTP server
// ────────────────────────────────────────────────────────────────────

let daemonReady = false;
let hasSecret = false;

async function handleSignImportToken(req, res, body) {
  if (!hasSecret) {
    return reply(res, 503, { error: "desktop auth not yet registered with daemon" });
  }
  const { baseDir, ttlMs } = body || {};
  if (typeof baseDir !== "string" || baseDir.length === 0) {
    return reply(res, 400, { error: "baseDir required" });
  }
  const ttl = Number.isInteger(ttlMs) && ttlMs > 0 && ttlMs <= DEFAULT_TTL_MS * 2 ? ttlMs : DEFAULT_TTL_MS;
  const minted = mintImportToken(baseDir, ttl);
  return reply(res, 200, minted);
}

async function handleImportFolder(req, res, body) {
  if (!hasSecret) {
    return reply(res, 503, { error: "desktop auth not yet registered with daemon" });
  }
  const { baseDir } = body || {};
  if (typeof baseDir !== "string" || baseDir.length === 0) {
    return reply(res, 400, { error: "baseDir required" });
  }
  const { token } = mintImportToken(baseDir, DEFAULT_TTL_MS);
  try {
    const odResponse = await fetch(`http://127.0.0.1:${DAEMON_PORT}/api/import/folder`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-od-desktop-import-token": token,
      },
      body: JSON.stringify({ baseDir, fromTrustedPicker: true }),
    });
    const odBody = await odResponse.json().catch(() => ({}));
    return reply(res, odResponse.status, odBody);
  } catch (err) {
    return reply(res, 502, { error: `daemon proxy failed: ${err.message}` });
  }
}

function handleHealth(req, res) {
  return reply(res, 200, { ok: true, daemonReady, hasSecret });
}

function reply(res, status, body) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function isLoopback(req) {
  const addr = req.socket?.remoteAddress;
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

const server = createServer(async (req, res) => {
  if (!isLoopback(req)) {
    res.statusCode = 403; res.end("loopback only"); return;
  }
  if (req.method === "GET" && req.url === "/health") {
    return handleHealth(req, res);
  }
  if (req.method !== "POST") {
    res.statusCode = 405; res.end("POST required"); return;
  }
  const chunks = [];
  let total = 0;
  const MAX = 64 * 1024;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > MAX) { res.statusCode = 413; res.end("payload too large"); return; }
    chunks.push(chunk);
  }
  let body = {};
  try { body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); }
  catch { res.statusCode = 400; res.end("invalid JSON"); return; }

  if (req.url === "/sign-import-token") return handleSignImportToken(req, res, body);
  if (req.url === "/import-folder")    return handleImportFolder(req, res, body);
  res.statusCode = 404; res.end("not found");
});

async function listenWithProbe(startPort) {
  for (let port = startPort; port < startPort + 50; port++) {
    try {
      await new Promise((resolve, reject) => {
        const onError = (err) => { server.off("listening", onListen); reject(err); };
        const onListen = () => { server.off("error", onError); resolve(); };
        server.once("error", onError);
        server.once("listening", onListen);
        server.listen(port, "127.0.0.1");
      });
      console.log(`[bridge] listening on 127.0.0.1:${port}`);
      // Stamp the chosen port to a file so OpenDesignDaemonManager can read it.
      const stampPath = join(DATA_DIR || "/tmp", ".clawdmeter-bridge-port");
      const { writeFileSync } = await import("node:fs");
      writeFileSync(stampPath, String(port), { mode: 0o600 });
      return port;
    } catch (err) {
      if (err.code !== "EADDRINUSE") throw err;
    }
  }
  throw new Error("no free port found in probe range");
}

async function main() {
  console.log("[bridge] starting clawdmeter-bridge-host");
  await listenWithProbe(DEFAULT_BRIDGE_PORT);
  // Probe daemon /health until ready, then register secret.
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${DAEMON_PORT}/health`);
      if (r.ok) { daemonReady = true; break; }
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  if (!daemonReady) {
    console.error("[bridge] daemon did not reach /health within 30s — bridge will reject sign/import requests");
    return;
  }
  const reg = await registerWithDaemon();
  hasSecret = reg.ok;
  if (reg.ok) {
    console.log("[bridge] HMAC secret registered with daemon");
  } else {
    console.error(`[bridge] secret registration FAILED: ${reg.reason}`);
    console.error("[bridge] Code→Design handoff inert until this is resolved");
  }
}

process.on("SIGTERM", () => { server.close(() => process.exit(0)); });
process.on("SIGINT",  () => { server.close(() => process.exit(0)); });

main().catch(err => { console.error("[bridge] fatal:", err); process.exit(1); });
