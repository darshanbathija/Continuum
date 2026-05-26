// Bearer auth — reference shape for both this gateway and the E2 relay
// Worker. The Mac daemon presents `Authorization: Bearer <token>` where the
// token is derived from the per-pairing session via HMAC-SHA256:
//
//   token = base64url( HMAC-SHA256(RELAY_BEARER_SIGNING_KEY,
//                                  "apns:" + sessionId + ":" + macFingerprint) )
//
// The operator-side signing key is shared between the relay Worker and the
// APNS gateway Worker so the token issued at pairing time on the relay path
// also authorizes the Mac to POST APNS pushes on this gateway path. Per
// design doc §4.1 the Mac side gets `macTok` at pairing, which is the
// `apns:` variant for the gateway and `relay:` for the relay.
//
// Why HMAC-not-JWT: smaller (no JSON header overhead), no parsing surface,
// constant-verification-cost, no clock skew concerns. The session id +
// fingerprint already pin the token to a single pairing; an expiration
// would only duplicate the pairing TTL.

import { hmacSha256Base64, verifyHmacSha256Base64 } from "./crypto-utils.js";
import type { Env } from "./env.js";

const BEARER_PREFIX = /^bearer\s+/i;

export type AuthResult =
  | { ok: true; sessionId: string; senderMacFingerprint: string }
  | { ok: false; reason: string };

export interface AuthClaim {
  readonly sessionId: string;
  readonly senderMacFingerprint: string;
}

export function expectedTokenMessage(claim: AuthClaim): string {
  return `apns:${claim.sessionId}:${claim.senderMacFingerprint}`;
}

/**
 * Helper for the Mac daemon side. Lives here so cross-impl tests can
 * exercise the round-trip without re-implementing the formula.
 */
export async function issueBearerToken(
  signingKeyBase64: string,
  claim: AuthClaim,
): Promise<string> {
  return await hmacSha256Base64(signingKeyBase64, expectedTokenMessage(claim));
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
  const ok = await verifyHmacSha256Base64(
    env.RELAY_BEARER_SIGNING_KEY,
    expectedTokenMessage(claim),
    token,
  );
  if (!ok) {
    return { ok: false, reason: "bearer signature mismatch" };
  }
  return { ok: true, ...claim };
}
