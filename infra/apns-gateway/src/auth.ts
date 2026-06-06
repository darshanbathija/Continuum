// Bearer auth — reference shape for both this gateway and the E2 relay
// Worker. The Mac daemon presents `Authorization: Bearer <token>` where the
// token is derived from the per-pairing session via HMAC-SHA256:
//
//   token = "v1." + issuedAtSeconds + "." + nonce + "." +
//           base64url( HMAC-SHA256(RELAY_BEARER_SIGNING_KEY,
//                                  "apns:" + sessionId + ":" + macFingerprint
//                                  + ":" + issuedAtSeconds + ":" + nonce) )
//
// The operator-side signing key is shared between the relay Worker and the
// APNS gateway Worker so the token issued at pairing time on the relay path
// also authorizes the Mac to POST APNS pushes on this gateway path. Per
// design doc §4.1 the Mac side gets `macTok` at pairing, which is the
// `apns:` variant for the gateway and `relay:` for the relay.
//
// Why HMAC-not-JWT: smaller (no JSON header overhead), constant verification
// cost, and a narrow parse surface. The issuedAt + nonce envelope gives us
// explicit expiry and one-use replay protection without exposing pairing
// secrets.

import {
  base64UrlEncode,
  hmacSha256Base64,
  sha256HexOfString,
  verifyHmacSha256Base64,
} from "./crypto-utils.js";
import type { Env } from "./env.js";
import { bearerTtlSeconds } from "./env.js";

const BEARER_PREFIX = /^bearer\s+/i;
const TOKEN_VERSION = "v1";
const NONCE_RE = /^[A-Za-z0-9_-]{16,128}$/;
const SIGNATURE_RE = /^[A-Za-z0-9+/=_-]{16,}$/;
const FUTURE_SKEW_SECONDS = 60;

export type AuthResult =
  | { ok: true; sessionId: string; senderMacFingerprint: string }
  | { ok: false; reason: string };

export interface AuthClaim {
  readonly sessionId: string;
  readonly senderMacFingerprint: string;
}

export interface BearerIssueOptions {
  readonly issuedAtSeconds?: number;
  readonly nonce?: string;
}

interface ParsedBearerToken {
  readonly issuedAtSeconds: number;
  readonly nonce: string;
  readonly signature: string;
}

export function expectedTokenMessage(
  claim: AuthClaim,
  issuedAtSeconds: number,
  nonce: string,
): string {
  return `apns:${claim.sessionId}:${claim.senderMacFingerprint}:${issuedAtSeconds}:${nonce}`;
}

export async function deriveAPNSSessionSigningKey(
  relayBearerSigningKeyBase64: string,
  claim: AuthClaim,
): Promise<string> {
  return await hmacSha256Base64(
    relayBearerSigningKeyBase64,
    `apns-session-key:${claim.sessionId}:${claim.senderMacFingerprint}`,
  );
}

/**
 * Helper for the Mac daemon side. Lives here so cross-impl tests can
 * exercise the round-trip without re-implementing the formula.
 */
export async function issueBearerToken(
  signingKeyBase64: string,
  claim: AuthClaim,
  opts: BearerIssueOptions = {},
): Promise<string> {
  const issuedAtSeconds = opts.issuedAtSeconds ?? Math.floor(Date.now() / 1000);
  const nonce = opts.nonce ?? newNonce();
  const signature = await hmacSha256Base64(
    signingKeyBase64,
    expectedTokenMessage(claim, issuedAtSeconds, nonce),
  );
  return `${TOKEN_VERSION}.${issuedAtSeconds}.${nonce}.${signature}`;
}

/**
 * Verifies the Authorization header against the (sessionId, senderFingerprint)
 * pair in the request body. The body fields must be present in the request
 * — the auth layer requires the body to be parsed first so we have something
 * to bind the token to.
 */
export async function verifyBearer(
  env: Env,
  authHeader: string | null,
  claim: AuthClaim,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<AuthResult> {
  if (!authHeader) {
    return { ok: false, reason: "missing Authorization header" };
  }
  if (!BEARER_PREFIX.test(authHeader)) {
    return { ok: false, reason: "Authorization must be Bearer scheme" };
  }
  const token = authHeader.replace(BEARER_PREFIX, "").trim();
  if (!token) {
    return { ok: false, reason: "empty bearer token" };
  }
  const parsed = parseBearerToken(token);
  if (!parsed) {
    return { ok: false, reason: "malformed bearer token" };
  }
  const ttl = bearerTtlSeconds(env);
  if (parsed.issuedAtSeconds > nowSeconds + FUTURE_SKEW_SECONDS) {
    return { ok: false, reason: "bearer issued in the future" };
  }
  if (nowSeconds - parsed.issuedAtSeconds > ttl) {
    return { ok: false, reason: "bearer expired" };
  }
  const message = expectedTokenMessage(claim, parsed.issuedAtSeconds, parsed.nonce);
  const sessionSigningKey = await deriveAPNSSessionSigningKey(env.RELAY_BEARER_SIGNING_KEY, claim);
  const ok =
    await verifyHmacSha256Base64(sessionSigningKey, message, parsed.signature) ||
    await verifyHmacSha256Base64(env.RELAY_BEARER_SIGNING_KEY, message, parsed.signature);
  if (!ok) {
    return { ok: false, reason: "bearer signature mismatch" };
  }
  const nonceFresh = await consumeBearerNonce(env, claim, parsed, ttl);
  if (!nonceFresh) {
    return { ok: false, reason: "bearer nonce replay" };
  }
  return { ok: true, ...claim };
}

function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

function parseBearerToken(token: string): ParsedBearerToken | null {
  const parts = token.split(".");
  if (parts.length !== 4 || parts[0] !== TOKEN_VERSION) return null;
  const issuedAtSeconds = Number.parseInt(parts[1]!, 10);
  const nonce = parts[2]!;
  const signature = parts[3]!;
  if (!Number.isFinite(issuedAtSeconds) || issuedAtSeconds <= 0) return null;
  if (!NONCE_RE.test(nonce)) return null;
  if (!SIGNATURE_RE.test(signature)) return null;
  return { issuedAtSeconds, nonce, signature };
}

async function consumeBearerNonce(
  env: Env,
  claim: AuthClaim,
  token: ParsedBearerToken,
  ttlSeconds: number,
): Promise<boolean> {
  const nonceHash = await sha256HexOfString(
    `apns-bearer-nonce:${claim.sessionId}:${claim.senderMacFingerprint}:${token.issuedAtSeconds}:${token.nonce}`,
  );
  const key = `bearer-nonce:${nonceHash}`;
  const existing = await env.APNS_RATE_LIMIT.get(key);
  if (existing !== null) return false;
  await env.APNS_RATE_LIMIT.put(key, "1", {
    expirationTtl: Math.max(60, ttlSeconds + FUTURE_SKEW_SECONDS),
  });
  return true;
}
