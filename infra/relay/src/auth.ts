// auth.ts — Bearer token validation for the relay Worker (D22: per-peer auth).
//
// Per the design doc (docs/design/secure-relay-apns-2026-05-26.md §4.1), each
// pairing session is provisioned with TWO opaque 256-bit bearer tokens at
// QR-generation time:
//
//   - macTok  → authorizes the Mac peer's WebSocket open
//   - iosTok  → authorizes the iOS peer's WebSocket open
//
// Per D22, a peer presenting the OTHER side's token is rejected even if the
// session ID matches. This is the post-codex-eng-review #4 hardening that makes
// a leaked QR compromise only one half of the session, not the whole channel.
//
// The relay learns the canonical `(macTok, iosTok)` pair the first time a peer
// connects (the first peer to arrive uploads BOTH tokens — they came from the
// QR they generated). The DO stores the hash of each token, and every
// subsequent connection on that session must match one of the two.

/** Result of validating a presented bearer token against a session's known pair. */
export type AuthResult =
  | { ok: true; role: PeerRole }
  | { ok: false; reason: AuthFailureReason };

export type PeerRole = "mac" | "ios";

export type AuthFailureReason =
  | "missing-authorization"
  | "malformed-bearer"
  | "unknown-session"
  | "token-mismatch"
  | "session-expired"
  | "session-full";

/** Stored on the DO; opaque to the relay operator. */
export interface SessionAuthBundle {
  /** SHA-256 hex of `macTok`. */
  macTokenHash: string;
  /** SHA-256 hex of `iosTok`. */
  iosTokenHash: string;
  /** Unix seconds; the relay rejects any connection (or reconnection) past this. */
  ttlSeconds: number;
}

/**
 * Constant-time string equality. JS `===` short-circuits on first mismatch,
 * which leaks token-prefix info via timing. SubtleCrypto.timingSafeEqual is
 * not exposed in Workers, so we roll our own over equal-length ASCII hex.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

/**
 * Extract a bearer token from an HTTP Request. WebSocket upgrade requests
 * cannot carry custom headers in browsers (the WebSocket constructor only
 * accepts a subprotocol), so we accept the token from EITHER:
 *
 *   - `Authorization: Bearer <token>` header (preferred for native clients)
 *   - `?token=<token>` query string (fallback for browser/test clients)
 *   - `Sec-WebSocket-Protocol: bearer.<token>` subprotocol (browser-safe)
 *
 * The token is the raw 64-char lowercase hex SHA-256-of-something or a 32-byte
 * base64 string. We just check shape; the DO does the equality check.
 */
export function extractBearerToken(request: Request): string | null {
  const auth = request.headers.get("authorization");
  if (auth) {
    const m = /^bearer\s+(.+)$/i.exec(auth);
    if (m) return m[1].trim();
  }

  const url = new URL(request.url);
  const queryToken = url.searchParams.get("token");
  if (queryToken) return queryToken.trim();

  const subproto = request.headers.get("sec-websocket-protocol");
  if (subproto) {
    // Format: "bearer.<token>" — accept first matching entry in a comma list.
    const parts = subproto.split(",").map((p) => p.trim());
    for (const p of parts) {
      if (p.startsWith("bearer.")) return p.slice("bearer.".length);
    }
  }

  return null;
}

/**
 * Hash a presented token with SHA-256. The DO stores ONLY hashes — even an
 * operator with full DO storage read access cannot recover the raw tokens.
 */
export async function hashToken(token: string): Promise<string> {
  const enc = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", enc);
  return bytesToHex(new Uint8Array(digest));
}

function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

/**
 * Validate a presented token against the stored bundle.
 *
 * Hashing is intentional — we never compare raw tokens; we compare their
 * SHA-256 hashes in constant time. This means the DO storage at rest never
 * contains the raw bearer; even a forensic dump of the session DO leaks only
 * hashes.
 */
export async function validateBearer(
  presentedToken: string,
  bundle: SessionAuthBundle,
  nowSeconds: number
): Promise<AuthResult> {
  if (nowSeconds >= bundle.ttlSeconds) {
    return { ok: false, reason: "session-expired" };
  }
  const presentedHash = await hashToken(presentedToken);
  if (constantTimeEqual(presentedHash, bundle.macTokenHash)) {
    return { ok: true, role: "mac" };
  }
  if (constantTimeEqual(presentedHash, bundle.iosTokenHash)) {
    return { ok: true, role: "ios" };
  }
  return { ok: false, reason: "token-mismatch" };
}

/** Sanity-check the shape of the auth bundle the first peer uploads. */
export function isValidAuthBundle(value: unknown): value is SessionAuthBundle {
  if (!value || typeof value !== "object") return false;
  const o = value as Record<string, unknown>;
  if (typeof o.macTokenHash !== "string" || !/^[0-9a-f]{64}$/.test(o.macTokenHash)) return false;
  if (typeof o.iosTokenHash !== "string" || !/^[0-9a-f]{64}$/.test(o.iosTokenHash)) return false;
  if (typeof o.ttlSeconds !== "number" || !Number.isFinite(o.ttlSeconds) || o.ttlSeconds <= 0) return false;
  // Reject mac == ios — would let a single token authorize both peers.
  if (o.macTokenHash === o.iosTokenHash) return false;
  return true;
}
