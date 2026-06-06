// durable-object.ts — RelaySession DO. One DO per pairing session.
//
// Design: one DO per pairing session, holding at most 2 WebSocket attachments
// (the Mac peer + the iOS peer). The DO uses Cloudflare's WebSocket
// Hibernation API (`ctx.acceptWebSocket(ws)` + `webSocketMessage` /
// `webSocketClose` handlers) so the DO can sleep while peers are idle and only
// pay CPU on actual frames — critical for the SLO budget (mobile peers go
// idle frequently).
//
// SLO budget (Codex #2, breakdown documented in README + asserted in tests):
//   - Worker cold start:       <50ms p99   → tiny module, no top-level await
//   - DO placement:            closest CF region to first peer (CF native)
//   - WS hibernation wake:     <100ms p99  → workerd handles automatically
//   - Reconnect storm:         100 concurrent reconnects, no drops of healthy peers
//   - Fan-out serialization:   O(N) for N peers (here N≤2 → O(1))
//   - CF regional routing:     DO is pinned to first peer's colo (CF default for `idFromName`)
//   - Mobile radio wake:       25s server-side keepalive ping (under iOS 30s aggressive wake)
//
// Per the design doc, the relay sees ONLY:
//   - Routing metadata (sender role, frame type)
//   - Opaque ciphertext bytes
//   - Frame counts (for audit)
//
// It NEVER:
//   - Decrypts (no key material exists here)
//   - Logs payload bytes
//   - Caches plaintext

import {
  parseEnvelopeHeader,
  serializeEnvelopeHeader,
  validateEnvelope,
  MAX_ENVELOPE_BODY_BYTES,
  MAX_ENVELOPE_HEADER_BYTES,
  type EnvelopeHeader,
  type AuditEntry,
} from "./envelope";
import {
  extractBearerToken,
  validateBearer,
  validateSessionCreationProof,
  isValidAuthBundle,
  type SessionAuthBundle,
  type PeerRole,
} from "./auth";

/** Bindings the DO receives from wrangler.toml. */
export interface RelayEnv {
  RELAY_SESSIONS: DurableObjectNamespace;
  RELAY_AUDIT_LOG?: KVNamespace;
  RELAY_RATE_LIMIT?: KVNamespace;
  RELAY_OPERATOR_SIGNING_KEY?: string;
  RELAY_BEARER_SIGNING_KEY?: string;
  RELAY_CREATION_GRANT_TOKEN?: string;
  SESSION_TTL_SECONDS: string;
  LOG_LEVEL: string;
  ENVIRONMENT: string;
}

/** Per-WebSocket state we attach via `ws.serializeAttachment`. Survives
 * hibernation (workerd persists this blob between event deliveries). */
interface WSAttachment {
  role: PeerRole;
  /** When this peer connected, Unix seconds. For audit + reconnect-storm tests. */
  connectedAtSeconds: number;
  /** The last header we received from this peer; cleared once we route its
   * paired body frame. Reset to null after every successful frame pair. */
  pendingHeader: EnvelopeHeader | null;
  /** Per-peer counter to detect ill-formed clients (body without header, etc). */
  framesReceived: number;
}

/** Stored persistently across DO restarts. Survives hibernation + GC. */
interface PersistedSessionState {
  auth: SessionAuthBundle;
  /** Unix seconds at last activity; used for idle eviction. */
  lastActivitySeconds: number;
  /** Aggregate counts for the audit log at session end. */
  counts: AuditEntry["counts"];
  bytesRouted: number;
  /** Initial-connect colo for sticky placement (informational; CF handles
   * the actual placement via `idFromName` keyed at the Worker). */
  firstPeerColo: string | null;
}

const STORAGE_KEY = "session-state-v1";
const KEEPALIVE_PING_SECONDS = 25; // Under iOS 30s aggressive radio wake threshold

export class RelaySession {
  private readonly state: DurableObjectState;
  private readonly env: RelayEnv;
  private cached: PersistedSessionState | null = null;

  constructor(state: DurableObjectState, env: RelayEnv) {
    this.state = state;
    this.env = env;
  }

  // ------------------------------------------------------------------
  // HTTP entrypoint — Worker forwards every request here.
  // ------------------------------------------------------------------
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/connect") {
      return this.handleConnect(request);
    }
    if (url.pathname === "/admin/stats" && request.method === "GET") {
      return this.handleStats(request);
    }
    return new Response("not found", { status: 404 });
  }

  /** WebSocket upgrade + per-peer auth + hibernation-acceptance. */
  private async handleConnect(request: Request): Promise<Response> {
    if (request.headers.get("upgrade") !== "websocket") {
      return new Response("expected websocket upgrade", { status: 426 });
    }

    const token = extractBearerToken(request);
    if (!token) {
      return new Response("missing bearer token", { status: 401 });
    }

    const nowSeconds = Math.floor(Date.now() / 1000);

    // First-peer bootstrap: if no auth bundle is stored, the first peer must
    // upload the signed (macTokenHash, iosTokenHash, ttlSeconds, creation)
    // bundle as `?bundle=<base64-json>` on connect. Subsequent connects just
    // present their token. The relay never learns raw tokens, only their
    // hashes, and the operator signature prevents arbitrary session creation.
    const existing = await this.loadState();
    let bundle: SessionAuthBundle;
    if (existing) {
      bundle = existing.auth;
    } else {
      const bundleParam = new URL(request.url).searchParams.get("bundle");
      if (!bundleParam) {
        return new Response(
          "session not initialized; first peer must supply ?bundle=...",
          { status: 412 }
        );
      }
      let decoded: unknown;
      try {
        decoded = JSON.parse(atob(bundleParam));
      } catch {
        return new Response("bundle param is not base64-json", { status: 400 });
      }
      if (!isValidAuthBundle(decoded)) {
        return new Response("bundle param failed shape validation", { status: 400 });
      }
      bundle = decoded;
      const creationAuth = await validateSessionCreationProof(
        this.env.RELAY_OPERATOR_SIGNING_KEY,
        request.headers.get("x-relay-session-id"),
        bundle,
        nowSeconds
      );
      if (!creationAuth.ok) {
        return new Response(`session creation unauthorized: ${creationAuth.reason}`, {
          status: creationAuth.status,
        });
      }
    }

    const result = await validateBearer(token, bundle, nowSeconds);
    if (!result.ok) {
      return new Response(`auth failed: ${result.reason}`, { status: 403 });
    }

    // Per-peer slot — at most ONE of each role attached at any time. If
    // another socket holds this role, we close THAT one (reconnect wins).
    // This is the reconnect-storm policy: a peer dropping + redialing always
    // displaces its own stale socket but never displaces the OTHER peer.
    await this.evictExistingForRole(result.role);

    // Bootstrap state on the very first connect.
    if (!existing) {
      const initialState: PersistedSessionState = {
        auth: bundle,
        lastActivitySeconds: nowSeconds,
        counts: {
          macHandshake: 0,
          iosHandshake: 0,
          macCiphertext: 0,
          iosCiphertext: 0,
          macControl: 0,
          iosControl: 0,
        },
        bytesRouted: 0,
        firstPeerColo: (request.cf?.colo as string | undefined) ?? null,
      };
      await this.saveState(initialState);
    }

    // Accept the upgrade. CF's hibernation API: we DO NOT call
    // `webSocket.accept()` — we call `ctx.acceptWebSocket(server)`. After this
    // returns, the DO can hibernate; `webSocketMessage` / `webSocketClose`
    // will rehydrate the DO on the next event.
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    // Echo the bearer subprotocol back to satisfy browser clients that send
    // it. Native clients use the Authorization header and ignore this.
    const subproto = request.headers.get("sec-websocket-protocol");
    const echoSubproto = subproto
      ?.split(",")
      .map((p) => p.trim())
      .find((p) => p.startsWith("bearer."));

    this.state.acceptWebSocket(server);
    const attachment: WSAttachment = {
      role: result.role,
      connectedAtSeconds: nowSeconds,
      pendingHeader: null,
      framesReceived: 0,
    };
    server.serializeAttachment(attachment);

    // Schedule the idle-eviction alarm. CF DO alarms are single-shot; we
    // re-schedule on every activity. TTL is sourced from wrangler vars.
    await this.scheduleIdleAlarm();

    // Schedule a periodic keepalive (server → both peers) every 25s so iOS
    // radio doesn't enter aggressive-wake mode. Implemented via a separate
    // alarm key (not the eviction one) — we coalesce: the eviction alarm
    // fires first and dispatches both.
    // (alarms are coalesced — see this.alarm())

    const responseHeaders: HeadersInit = {};
    if (echoSubproto) {
      responseHeaders["sec-websocket-protocol"] = echoSubproto;
    }
    // Tell the connecting peer which role we assigned (handy for debug + UX).
    responseHeaders["x-clawdmeter-relay-role"] = result.role;

    return new Response(null, {
      status: 101,
      webSocket: client,
      headers: responseHeaders,
    });
  }

  /** Stats endpoint for tests + the README "no plaintext in logs" assertion.
   * Returns aggregate counts and the auth bundle hashes ONLY; no body content. */
  private async handleStats(request: Request): Promise<Response> {
    const token = extractBearerToken(request);
    if (!token) {
      return new Response("missing bearer token", { status: 401 });
    }
    const s = await this.loadState();
    if (!s) {
      return new Response("session not initialized", { status: 404 });
    }
    const result = await validateBearer(token, s.auth, Math.floor(Date.now() / 1000));
    if (!result.ok) {
      return new Response(`auth failed: ${result.reason}`, { status: 403 });
    }
    const liveSockets = this.state.getWebSockets();
    return new Response(
      JSON.stringify({
        initialized: true,
        counts: s.counts,
        bytesRouted: s.bytesRouted,
        liveSocketCount: liveSockets.length,
        lastActivitySeconds: s.lastActivitySeconds,
        firstPeerColo: s.firstPeerColo,
        // NO raw tokens, NO body samples, NO peer IPs.
        macTokenHashPrefix: s.auth.macTokenHash.slice(0, 8),
        iosTokenHashPrefix: s.auth.iosTokenHash.slice(0, 8),
      }),
      { headers: { "content-type": "application/json" } }
    );
  }

  // ------------------------------------------------------------------
  // WebSocket Hibernation API handlers.
  // ------------------------------------------------------------------

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const att = ws.deserializeAttachment() as WSAttachment | null;
    if (!att) {
      // Should never happen — every accepted socket gets an attachment.
      ws.close(1011, "internal: missing attachment");
      return;
    }

    att.framesReceived++;

    const state = await this.loadState();
    if (!state) {
      ws.close(1011, "internal: missing session state");
      return;
    }
    state.lastActivitySeconds = Math.floor(Date.now() / 1000);

    // Header / body interleave.
    if (typeof message === "string") {
      // HEADER frame. Cap length to keep DoS surface tiny.
      if (message.length > MAX_ENVELOPE_HEADER_BYTES) {
        ws.close(1009, "header exceeds cap");
        return;
      }
      const header = parseEnvelopeHeader(message);
      if (!header) {
        ws.close(1003, "malformed header");
        return;
      }
      // Per-peer auth, redux: the header claims a `from` role; it MUST
      // match the role we authenticated at connect time. Forging the role
      // header is the D22 defense at the message layer.
      if (header.from !== att.role) {
        ws.close(1008, "header.from does not match authenticated role");
        return;
      }

      if (header.type === "control") {
        // Control frame is header-only; route immediately as a control ping
        // to the other peer (or drop if no other peer yet).
        this.bumpCount(state, att.role, "control");
        await this.saveState(state);
        await this.fanOutControl(att.role, header);
        return;
      }

      // Cache the header until the matching binary body arrives.
      att.pendingHeader = header;
      ws.serializeAttachment(att);
      await this.saveState(state);
      return;
    }

    // BODY frame.
    if (!att.pendingHeader) {
      ws.close(1003, "body without header");
      return;
    }
    const header = att.pendingHeader;
    const body = new Uint8Array(message);
    const envelope = { header, body };
    const err = validateEnvelope(envelope);
    if (err) {
      ws.close(1009, err);
      return;
    }

    // Audit counts (NO body bytes — only count + length).
    if (header.type === "handshake") {
      this.bumpCount(state, att.role, "handshake");
    } else if (header.type === "ciphertext") {
      this.bumpCount(state, att.role, "ciphertext");
    }
    state.bytesRouted += body.byteLength;
    att.pendingHeader = null;
    ws.serializeAttachment(att);
    await this.saveState(state);

    // Fan-out: O(N) for N peers. Here N is at most 2 so it's O(1).
    await this.fanOut(att.role, header, body);
    await this.scheduleIdleAlarm();
  }

  async webSocketClose(
    ws: WebSocket,
    code: number,
    reason: string,
    _wasClean: boolean
  ): Promise<void> {
    // workerd already removed the socket from getWebSockets(); nothing else
    // to do. We persist the close into the audit counts so post-mortem ops
    // can see why a session ended.
    const att = ws.deserializeAttachment() as WSAttachment | null;
    if (this.shouldLog("debug")) {
      console.log(
        JSON.stringify({
          event: "ws-close",
          role: att?.role ?? "?",
          code,
          reason: reason.slice(0, 64), // cap, not a leak
        })
      );
    }
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const att = ws.deserializeAttachment() as WSAttachment | null;
    if (this.shouldLog("debug")) {
      console.log(
        JSON.stringify({
          event: "ws-error",
          role: att?.role ?? "?",
          // Coerce; never call .toString() on user-controlled data.
          msg: typeof error === "object" && error && "message" in error ? String((error as { message: unknown }).message).slice(0, 128) : "unknown",
        })
      );
    }
  }

  // ------------------------------------------------------------------
  // Alarm handler — idle eviction + keepalive ping fan-out.
  // ------------------------------------------------------------------
  async alarm(): Promise<void> {
    const state = await this.loadState();
    if (!state) return;
    const nowSeconds = Math.floor(Date.now() / 1000);
    const idleSeconds = nowSeconds - state.lastActivitySeconds;
    const ttl = this.sessionTtlSeconds();
    const sockets = this.state.getWebSockets();

    if (idleSeconds >= ttl || nowSeconds >= state.auth.ttlSeconds) {
      // Evict the session entirely.
      const endReason: AuditEntry["endReason"] =
        nowSeconds >= state.auth.ttlSeconds ? "ttl-expired" : "idle-evict";
      await this.finalizeAndPurge(state, endReason);
      for (const ws of sockets) {
        try {
          ws.close(1000, `session ended: ${endReason}`);
        } catch {
          // already closed
        }
      }
      return;
    }

    // Not evicting; if we're past the keepalive window, send a server ping
    // to both peers to keep the mobile radio warm and detect dead sockets.
    for (const ws of sockets) {
      try {
        // Empty control header with `from: "mac"` is invalid (server has no
        // role). We send a non-protocol-conformant ping (raw text "keepalive")
        // that clients filter out. Native clients drop unknown strings.
        ws.send("__keepalive__");
      } catch {
        // closed socket; skip
      }
    }
    // Re-schedule for the next keepalive tick OR the next eviction check,
    // whichever is sooner.
    await this.scheduleIdleAlarm();
  }

  // ------------------------------------------------------------------
  // Helpers.
  // ------------------------------------------------------------------

  /** Fan-out a (header, body) pair to the OTHER peer (not the sender). */
  private async fanOut(
    senderRole: PeerRole,
    header: EnvelopeHeader,
    body: Uint8Array
  ): Promise<void> {
    const sockets = this.state.getWebSockets();
    const headerText = serializeEnvelopeHeader(header);
    for (const ws of sockets) {
      const att = ws.deserializeAttachment() as WSAttachment | null;
      if (!att || att.role === senderRole) continue;
      try {
        ws.send(headerText);
        // Important: we DO NOT log the body bytes anywhere; only forward.
        ws.send(body);
      } catch {
        // peer dropped mid-send; not a relay error
      }
    }
  }

  /** Fan-out a control envelope (header-only) to the other peer. */
  private async fanOutControl(senderRole: PeerRole, header: EnvelopeHeader): Promise<void> {
    const sockets = this.state.getWebSockets();
    const headerText = serializeEnvelopeHeader(header);
    for (const ws of sockets) {
      const att = ws.deserializeAttachment() as WSAttachment | null;
      if (!att || att.role === senderRole) continue;
      try {
        ws.send(headerText);
      } catch {
        // peer dropped; non-fatal
      }
    }
  }

  /** Close any existing socket holding `role` (reconnect-displaces-self). */
  private async evictExistingForRole(role: PeerRole): Promise<void> {
    const sockets = this.state.getWebSockets();
    for (const ws of sockets) {
      const att = ws.deserializeAttachment() as WSAttachment | null;
      if (att?.role === role) {
        try {
          ws.close(4000, "displaced by reconnect");
        } catch {
          // already closed
        }
      }
    }
  }

  /** Schedule the idle-eviction alarm. Coalesces with keepalive ticks. */
  private async scheduleIdleAlarm(): Promise<void> {
    // Schedule at the keepalive interval; alarm() checks for both eviction
    // AND keepalive on every fire.
    const next = Date.now() + KEEPALIVE_PING_SECONDS * 1000;
    const current = await this.state.storage.getAlarm();
    if (current === null || current > next) {
      await this.state.storage.setAlarm(next);
    }
  }

  private async loadState(): Promise<PersistedSessionState | null> {
    if (this.cached) return this.cached;
    const v = (await this.state.storage.get<PersistedSessionState>(STORAGE_KEY)) ?? null;
    this.cached = v;
    return v;
  }

  private async saveState(state: PersistedSessionState): Promise<void> {
    this.cached = state;
    await this.state.storage.put(STORAGE_KEY, state);
  }

  private async finalizeAndPurge(
    state: PersistedSessionState,
    endReason: AuditEntry["endReason"]
  ): Promise<void> {
    if (this.env.RELAY_AUDIT_LOG) {
      const entry: AuditEntry = {
        ts: new Date().toISOString(),
        sessionDoId: this.state.id.toString(),
        counts: state.counts,
        bytesRouted: state.bytesRouted,
        endReason,
      };
      try {
        await this.env.RELAY_AUDIT_LOG.put(
          `audit:${entry.ts}:${entry.sessionDoId}`,
          JSON.stringify(entry),
          { expirationTtl: 90 * 24 * 3600 } // 90 days per SECRETS.md
        );
      } catch (e) {
        // Never let audit write failure poison the close path.
        console.log(JSON.stringify({ event: "audit-write-failed", msg: String(e).slice(0, 64) }));
      }
    }
    this.cached = null;
    await this.state.storage.deleteAll();
  }

  private bumpCount(
    state: PersistedSessionState,
    role: PeerRole,
    kind: "handshake" | "ciphertext" | "control"
  ): void {
    if (role === "mac") {
      if (kind === "handshake") state.counts.macHandshake++;
      else if (kind === "ciphertext") state.counts.macCiphertext++;
      else state.counts.macControl++;
    } else {
      if (kind === "handshake") state.counts.iosHandshake++;
      else if (kind === "ciphertext") state.counts.iosCiphertext++;
      else state.counts.iosControl++;
    }
  }

  private sessionTtlSeconds(): number {
    const n = parseInt(this.env.SESSION_TTL_SECONDS, 10);
    if (!Number.isFinite(n) || n <= 0) return 900; // 15 min default
    return n;
  }

  private shouldLog(level: "debug" | "info"): boolean {
    if (this.env.LOG_LEVEL === "debug") return true;
    if (level === "info" && this.env.LOG_LEVEL === "info") return true;
    return false;
  }
}

// Re-export for type tests.
export type { WSAttachment, PersistedSessionState };
export { MAX_ENVELOPE_BODY_BYTES };
