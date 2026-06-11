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

export type CreationAuthResult =
  | { ok: true }
  | { ok: false; status: number; reason: string };

export type CreationGrantAuthorizationResult =
  | { ok: true }
  | { ok: false; status: number; reason: string };

export interface SessionCreationProof {
  /** Unix seconds. Keeps a copied bundle from authorizing creation forever. */
  issuedAtSeconds: number;
  /** Random base64url nonce. Bound into the signature. */
  nonce: string;
  /** base64url HMAC-SHA256 over the session id + bundle + issuedAt + nonce. */
  signature: string;
}

export interface SessionCreationGrantRequest {
  /** SHA-256 hex of `macTok`. */
  macTokenHash: string;
  /** SHA-256 hex of `iosTok`. */
  iosTokenHash: string;
  /** Absolute Unix seconds at which the session expires. */
  ttlSeconds: number;
  /** Mac APNS sender fingerprint. Present when the caller wants an APNS key. */
  senderMacFingerprint?: string;
}

export interface SessionCreationGrantResponse {
  creation: SessionCreationProof;
  /** Per-session APNS gateway bearer signing key, base64url encoded. */
  apnsSigningKey?: string;
}

/** Stored on the DO; opaque to the relay operator. */
export interface SessionAuthBundle {
  /** SHA-256 hex of `macTok`. */
  macTokenHash: string;
  /** SHA-256 hex of `iosTok`. */
  iosTokenHash: string;
  /** Unix seconds; the relay rejects any connection (or reconnection) past this. */
  ttlSeconds: number;
  /** Operator authorization required for first-peer session creation. */
  creation: SessionCreationProof;
}

const B64_ANY = /^[A-Za-z0-9+/=_-]+$/;
const NONCE_RE = /^[A-Za-z0-9_-]{16,128}$/;
const CREATION_PROOF_MAX_AGE_SECONDS = 300;
const CREATION_GRANT_MAX_TTL_SECONDS = 31 * 24 * 60 * 60;
const HEX64_RE = /^[0-9a-f]{64}$/;
const FINGERPRINT_RE = /^[A-Za-z0-9_-]{16,128}$/;

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

function base64Decode(b64: string): Uint8Array {
  const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

async function hmacSha256Base64Url(keyBase64: string, message: string): Promise<string> {
  const keyBytes = base64Decode(keyBase64);
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message) as BufferSource);
  return base64UrlEncode(new Uint8Array(sig));
}

function normalizeBase64(value: string): string {
  return value.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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

export function creationMessage(sessionId: string, bundle: SessionAuthBundle): string {
  return [
    "relay-create",
    sessionId,
    bundle.macTokenHash,
    bundle.iosTokenHash,
    String(bundle.ttlSeconds),
    String(bundle.creation.issuedAtSeconds),
    bundle.creation.nonce,
  ].join(":");
}

export async function issueSessionCreationSignature(
  operatorSigningKeyBase64: string,
  sessionId: string,
  bundle: SessionAuthBundle
): Promise<string> {
  return hmacSha256Base64Url(operatorSigningKeyBase64, creationMessage(sessionId, bundle));
}

export async function issueSessionCreationProof(
  operatorSigningKeyBase64: string,
  sessionId: string,
  request: SessionCreationGrantRequest,
  nowSeconds: number
): Promise<SessionCreationProof> {
  const bundle: SessionAuthBundle = {
    macTokenHash: request.macTokenHash,
    iosTokenHash: request.iosTokenHash,
    ttlSeconds: request.ttlSeconds,
    creation: {
      issuedAtSeconds: nowSeconds,
      nonce: newNonce(),
      signature: "pending",
    },
  };
  bundle.creation.signature = await issueSessionCreationSignature(
    operatorSigningKeyBase64,
    sessionId,
    bundle
  );
  return bundle.creation;
}

export async function deriveAPNSSessionSigningKey(
  relayBearerSigningKeyBase64: string,
  sessionId: string,
  senderMacFingerprint: string
): Promise<string> {
  return hmacSha256Base64Url(
    relayBearerSigningKeyBase64,
    `apns-session-key:${sessionId}:${senderMacFingerprint}`
  );
}

export async function validateSessionCreationProof(
  operatorSigningKeyBase64: string | undefined,
  sessionId: string | null,
  bundle: SessionAuthBundle,
  nowSeconds: number
): Promise<CreationAuthResult> {
  if (!operatorSigningKeyBase64) {
    return { ok: false, status: 500, reason: "relay operator signing key is not configured" };
  }
  if (!sessionId) {
    return { ok: false, status: 400, reason: "missing relay session id" };
  }
  const { creation } = bundle;
  if (nowSeconds < creation.issuedAtSeconds - 60) {
    return { ok: false, status: 403, reason: "creation proof issued in the future" };
  }
  if (nowSeconds - creation.issuedAtSeconds > CREATION_PROOF_MAX_AGE_SECONDS) {
    return { ok: false, status: 403, reason: "creation proof expired" };
  }
  const expected = await issueSessionCreationSignature(operatorSigningKeyBase64, sessionId, bundle);
  if (!constantTimeEqual(normalizeBase64(expected), normalizeBase64(creation.signature))) {
    return { ok: false, status: 403, reason: "creation proof signature mismatch" };
  }
  return { ok: true };
}

export async function validateCreationGrantAuthorization(
  configuredToken: string | undefined,
  authHeader: string | null,
  options?: {
    provisioningKeyBase64?: string;
    validateDeviceGrantToken?: (
      provisioningKeyBase64: string | undefined,
      presentedToken: string
    ) => Promise<boolean>;
  }
): Promise<CreationGrantAuthorizationResult> {
  if (!authHeader) {
    return { ok: false, status: 401, reason: "missing Authorization header" };
  }
  const match = /^bearer\s+(.+)$/i.exec(authHeader);
  if (!match) {
    return { ok: false, status: 401, reason: "Authorization must be Bearer scheme" };
  }
  const presented = match[1]?.trim() ?? "";
  if (!presented) {
    return { ok: false, status: 401, reason: "empty bearer token" };
  }

  if (configuredToken) {
    const [presentedHash, configuredHash] = await Promise.all([
      hashToken(presented),
      hashToken(configuredToken),
    ]);
    if (constantTimeEqual(presentedHash, configuredHash)) {
      return { ok: true };
    }
  }

  const validateDevice = options?.validateDeviceGrantToken;
  if (
    validateDevice &&
    (await validateDevice(options?.provisioningKeyBase64, presented))
  ) {
    return { ok: true };
  }

  if (!configuredToken && !options?.provisioningKeyBase64) {
    return { ok: false, status: 500, reason: "relay creation grant auth is not configured" };
  }
  return { ok: false, status: 403, reason: "creation grant token mismatch" };
}

/** Sanity-check the shape of the auth bundle the first peer uploads. */
export function isValidAuthBundle(value: unknown): value is SessionAuthBundle {
  if (!value || typeof value !== "object") return false;
  const o = value as Record<string, unknown>;
  if (typeof o.macTokenHash !== "string" || !/^[0-9a-f]{64}$/.test(o.macTokenHash)) return false;
  if (typeof o.iosTokenHash !== "string" || !/^[0-9a-f]{64}$/.test(o.iosTokenHash)) return false;
  if (typeof o.ttlSeconds !== "number" || !Number.isFinite(o.ttlSeconds) || o.ttlSeconds <= 0) return false;
  if (!o.creation || typeof o.creation !== "object") return false;
  const creation = o.creation as Record<string, unknown>;
  if (
    typeof creation.issuedAtSeconds !== "number" ||
    !Number.isFinite(creation.issuedAtSeconds) ||
    creation.issuedAtSeconds <= 0
  ) return false;
  if (typeof creation.nonce !== "string" || !NONCE_RE.test(creation.nonce)) return false;
  if (typeof creation.signature !== "string" || !B64_ANY.test(creation.signature) || creation.signature.length < 16) return false;
  // Reject mac == ios — would let a single token authorize both peers.
  if (o.macTokenHash === o.iosTokenHash) return false;
  return true;
}

export function isValidSessionCreationGrantRequest(
  value: unknown,
  nowSeconds: number
): value is SessionCreationGrantRequest {
  if (!value || typeof value !== "object") return false;
  const o = value as Record<string, unknown>;
  if (typeof o.macTokenHash !== "string" || !HEX64_RE.test(o.macTokenHash)) return false;
  if (typeof o.iosTokenHash !== "string" || !HEX64_RE.test(o.iosTokenHash)) return false;
  if (o.macTokenHash === o.iosTokenHash) return false;
  if (typeof o.ttlSeconds !== "number" || !Number.isFinite(o.ttlSeconds)) return false;
  if (o.ttlSeconds <= nowSeconds) return false;
  if (o.ttlSeconds > nowSeconds + CREATION_GRANT_MAX_TTL_SECONDS) return false;
  if (o.senderMacFingerprint !== undefined) {
    if (typeof o.senderMacFingerprint !== "string" || !FINGERPRINT_RE.test(o.senderMacFingerprint)) {
      return false;
    }
  }
  return true;
}
