// Codex #5 — device-token egress controls.
//
// Invariants:
// - The raw APNS device token is NEVER stored long-term. We SHA-256 it
//   immediately and only the hash goes into KV / logs.
// - Each hashed token is bound to a single pairing session id. A push from
//   a different session id targeting the same token is rejected as
//   cross-tenant (rejected-cross-tenant audit outcome).
// - APNS 410 ("Unregistered") responses purge the hashed token row.
// - DELETE /device-token (signed by the per-pairing HMAC) purges manually.

import type { Env } from "./env.js";
import { deviceTokenTtlSeconds } from "./env.js";
import { sha256HexOfHex } from "./crypto-utils.js";

export interface DeviceTokenBinding {
  /** Pairing session id this token was first registered under. */
  readonly sessionId: string;
  /** Unix seconds the binding was created. */
  readonly createdAt: number;
  /** Unix seconds we most recently saw a push for this token. */
  readonly lastSeenAt: number;
  /** Mac sender fingerprint that registered it (for audit). */
  readonly registeredBy: string;
}

function keyForHash(hash: string): string {
  return `dt:${hash}`;
}

/** SHA-256(deviceTokenHex). Returns the hex digest. */
export async function hashDeviceToken(deviceTokenHex: string): Promise<string> {
  return await sha256HexOfHex(deviceTokenHex);
}

export type BindResult =
  | { kind: "ok"; binding: DeviceTokenBinding; firstRegistration: boolean }
  | {
      kind: "cross-tenant";
      existing: DeviceTokenBinding;
      attemptedSessionId: string;
    };

/**
 * Ensures the (hashed token, sessionId) pair is consistent.
 *
 * - If no row exists → create one bound to sessionId.
 * - If a row exists for the SAME sessionId → bump lastSeenAt.
 * - If a row exists for a DIFFERENT sessionId → reject (cross-tenant).
 */
export async function bindDeviceToken(
  env: Env,
  deviceTokenHash: string,
  sessionId: string,
  registeredBy: string,
  nowSeconds: number,
): Promise<BindResult> {
  const key = keyForHash(deviceTokenHash);
  const existingRaw = await env.APNS_DEVICE_TOKENS.get(key);

  if (!existingRaw) {
    const binding: DeviceTokenBinding = {
      sessionId,
      createdAt: nowSeconds,
      lastSeenAt: nowSeconds,
      registeredBy,
    };
    await env.APNS_DEVICE_TOKENS.put(key, JSON.stringify(binding), {
      expirationTtl: deviceTokenTtlSeconds(env),
    });
    return { kind: "ok", binding, firstRegistration: true };
  }

  let existing: DeviceTokenBinding;
  try {
    existing = JSON.parse(existingRaw) as DeviceTokenBinding;
  } catch {
    // Corrupted row — treat as missing.
    const binding: DeviceTokenBinding = {
      sessionId,
      createdAt: nowSeconds,
      lastSeenAt: nowSeconds,
      registeredBy,
    };
    await env.APNS_DEVICE_TOKENS.put(key, JSON.stringify(binding), {
      expirationTtl: deviceTokenTtlSeconds(env),
    });
    return { kind: "ok", binding, firstRegistration: true };
  }

  if (existing.sessionId !== sessionId) {
    return { kind: "cross-tenant", existing, attemptedSessionId: sessionId };
  }

  const refreshed: DeviceTokenBinding = {
    ...existing,
    lastSeenAt: nowSeconds,
  };
  await env.APNS_DEVICE_TOKENS.put(key, JSON.stringify(refreshed), {
    expirationTtl: deviceTokenTtlSeconds(env),
  });
  return { kind: "ok", binding: refreshed, firstRegistration: false };
}

/** Reads the current binding without mutating. */
export async function lookupDeviceToken(
  env: Env,
  deviceTokenHash: string,
): Promise<DeviceTokenBinding | null> {
  const raw = await env.APNS_DEVICE_TOKENS.get(keyForHash(deviceTokenHash));
  if (!raw) return null;
  try {
    return JSON.parse(raw) as DeviceTokenBinding;
  } catch {
    return null;
  }
}

/**
 * Purges the row. Called from APNS 410 handling (stale token) + the
 * DELETE /device-token opt-out endpoint.
 */
export async function purgeDeviceToken(env: Env, deviceTokenHash: string): Promise<void> {
  await env.APNS_DEVICE_TOKENS.delete(keyForHash(deviceTokenHash));
}
