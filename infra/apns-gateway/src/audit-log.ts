// D21 mitigation suite — audit log of every push. Entries are written to
// KV (90-day TTL) AND emitted to the Workers Logs sink via console.log so
// the operator can grep both surfaces. NO plaintext payload — only the
// hashed device token + sender fingerprint + payload SIZE.

import type { Env } from "./env.js";
import { auditLogTtlSeconds } from "./env.js";

export type AuditOutcome =
  | "delivered"
  | "rejected-schema"
  | "rejected-auth"
  | "rejected-rate-limit"
  | "rejected-kill-switch"
  | "rejected-cross-tenant"
  | "rejected-disabled"
  | "apns-bad-token"
  | "apns-unregistered"
  | "apns-rate-limited"
  | "apns-server-error"
  | "transport-error"
  | "opt-out";

export interface AuditEntry {
  readonly ts: number; // Unix seconds
  readonly env: string;
  readonly outcome: AuditOutcome;
  /** SHA-256(deviceToken). Never the raw token. */
  readonly deviceTokenHash: string | null;
  /** Mac sender fingerprint, raw from request (already SHA-256 in the design doc). */
  readonly senderMacFingerprint: string | null;
  /** Pairing session id (codex #5 tenant binding visibility). */
  readonly sessionId: string | null;
  /** Bytes of the encryptedPayload (NEVER the payload itself). */
  readonly payloadSize: number | null;
  /** APNS response apns-id header (UUID) for cross-referencing with Apple. */
  readonly apnsId: string | null;
  /** APNS HTTP status (when the request reached Apple). */
  readonly apnsStatus: number | null;
  /** Optional reason string from APNS. */
  readonly reason: string | null;
  /** Request id we surface in the response header for correlation. */
  readonly requestId: string;
}

/**
 * KV key shape: `audit:<reverse-ts>:<requestId>`. Reverse-ts (so the
 * highest-ts entry sorts first) lets `wrangler kv key list --prefix` walk
 * the most recent entries cheaply for incident response.
 */
function auditKey(entry: AuditEntry): string {
  // 2^31-1 epoch seconds = ~year 2038; using a 13-digit anchored space.
  const reverse = (10_000_000_000 - entry.ts).toString().padStart(13, "0");
  return `audit:${reverse}:${entry.requestId}`;
}

export async function writeAudit(env: Env, entry: AuditEntry): Promise<void> {
  // 1. Console log (Workers Logs sink). Structured JSON so operators can
  //    grep by outcome + filter by env in the CF dashboard.
  console.log(JSON.stringify({ kind: "audit", ...entry }));

  // 2. KV persistence for incident replay. 90-day TTL.
  try {
    await env.APNS_AUDIT_LOG.put(auditKey(entry), JSON.stringify(entry), {
      expirationTtl: auditLogTtlSeconds(env),
    });
  } catch (e) {
    // Don't fail the request on audit write failure — log + carry on. The
    // console.log line above is the durable signal; KV is only convenient
    // for `wrangler kv key list` replay.
    console.error(
      JSON.stringify({
        kind: "audit-write-error",
        requestId: entry.requestId,
        error: e instanceof Error ? e.message : String(e),
      }),
    );
  }
}

/** Helper builder so call-sites stay tidy. */
export function makeAuditEntry(
  env: Env,
  base: Pick<AuditEntry, "outcome" | "requestId"> & Partial<AuditEntry>,
): AuditEntry {
  return {
    ts: base.ts ?? Math.floor(Date.now() / 1000),
    env: base.env ?? env.ENVIRONMENT,
    outcome: base.outcome,
    deviceTokenHash: base.deviceTokenHash ?? null,
    senderMacFingerprint: base.senderMacFingerprint ?? null,
    sessionId: base.sessionId ?? null,
    payloadSize: base.payloadSize ?? null,
    apnsId: base.apnsId ?? null,
    apnsStatus: base.apnsStatus ?? null,
    reason: base.reason ?? null,
    requestId: base.requestId,
  };
}
