// KV-backed per-device hourly counter (D21 mitigation suite). 60 pushes /
// device / hour by default; configurable via RATE_LIMIT_PER_HOUR var.
//
// We bucket by floor(nowSeconds / 3600) so the counter rolls over cleanly
// without needing a sliding-window store. Conservative — a burst at the
// minute-59 boundary gets a fresh budget at minute-00. Good enough for the
// abuse scenario (D21#2: stolen .p8 → push spam).
//
// KV is eventually consistent. We accept that a near-simultaneous double-
// check could pass one extra push through; the upper bound on slop is
// ~Nx (N = number of CF regions seeing the same token). Tolerable for an
// abuse mitigation — the audit log is the auth trail of record.

import type { Env } from "./env.js";
import { rateLimitPerHour } from "./env.js";

export interface RateLimitDecision {
  readonly allowed: boolean;
  readonly used: number;
  readonly limit: number;
  readonly bucket: number;
  /** Seconds until the current bucket resets. */
  readonly resetSeconds: number;
}

function bucketFor(nowSeconds: number): number {
  return Math.floor(nowSeconds / 3600);
}

function keyFor(deviceTokenHash: string, bucket: number): string {
  return `rl:${deviceTokenHash}:${bucket}`;
}

/**
 * Atomically checks + increments the counter. On the cold-path we use
 * KV.get → +1 → KV.put. Race conditions could leak a few extra requests
 * but that's fine for an abuse-mitigation rate limit.
 */
export async function checkRateLimit(
  env: Env,
  deviceTokenHash: string,
  nowSeconds: number,
): Promise<RateLimitDecision> {
  const limit = rateLimitPerHour(env);
  const bucket = bucketFor(nowSeconds);
  const key = keyFor(deviceTokenHash, bucket);

  const existing = await env.APNS_RATE_LIMIT.get(key);
  const used = existing ? Number.parseInt(existing, 10) || 0 : 0;
  const resetSeconds = 3600 - (nowSeconds % 3600);

  if (used >= limit) {
    return { allowed: false, used, limit, bucket, resetSeconds };
  }

  const next = used + 1;
  // 1h TTL on the counter — KV auto-purges when the bucket rolls.
  await env.APNS_RATE_LIMIT.put(key, String(next), {
    expirationTtl: 3600,
  });

  return { allowed: true, used: next, limit, bucket, resetSeconds };
}

/**
 * Read-only peek — used by GET /health and tests. Doesn't increment.
 */
export async function peekRateLimit(
  env: Env,
  deviceTokenHash: string,
  nowSeconds: number,
): Promise<RateLimitDecision> {
  const limit = rateLimitPerHour(env);
  const bucket = bucketFor(nowSeconds);
  const key = keyFor(deviceTokenHash, bucket);
  const existing = await env.APNS_RATE_LIMIT.get(key);
  const used = existing ? Number.parseInt(existing, 10) || 0 : 0;
  const resetSeconds = 3600 - (nowSeconds % 3600);
  return { allowed: used < limit, used, limit, bucket, resetSeconds };
}
