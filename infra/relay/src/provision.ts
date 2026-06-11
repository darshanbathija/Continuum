// provision.ts — Auto-provision per-Mac relay creation-grant tokens.
//
// Shipped Mac apps cannot embed the operator `RELAY_CREATION_GRANT_TOKEN`
// (extractable → public signing oracle). Instead they carry a separate
// `RELAY_CLIENT_PROVISIONING_KEY` and call `POST /v1/relay/provision/grant-token`
// once per install. The Worker returns a deterministic per-install grant token
// that `validateCreationGrantAuthorization` accepts alongside the operator bearer.

import { constantTimeEqual } from "./auth";

export const DEVICE_GRANT_PREFIX = "device-grant-v1:";
export const PROVISION_REQUEST_PREFIX = "grant-provision:";
export const PROVISION_RATE_LIMIT_PREFIX = "provision-rate:";

/** Max clock skew for provision requests (seconds). */
export const PROVISION_MAX_SKEW_SECONDS = 300;
/** Per-install provision attempts within the rolling window. */
export const PROVISION_RATE_LIMIT_MAX = 5;
/** Rolling window for provision rate limiting (seconds). */
export const PROVISION_RATE_LIMIT_WINDOW_SECONDS = 3600;

export interface GrantProvisionRequest {
  installId: string;
  issuedAtSeconds: number;
}

export type GrantProvisionValidationResult =
  | { ok: true; request: GrantProvisionRequest }
  | { ok: false; status: number; reason: string };

export type GrantProvisionRateLimitResult =
  | { ok: true }
  | { ok: false; status: number; reason: string };

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

const INSTALL_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isValidInstallId(value: string): boolean {
  return INSTALL_ID_RE.test(value);
}

export function provisionRequestMessage(installId: string, issuedAtSeconds: number): string {
  return `${PROVISION_REQUEST_PREFIX}${installId}:${issuedAtSeconds}`;
}

export async function issueProvisionRequestSignature(
  provisioningKeyBase64: string,
  installId: string,
  issuedAtSeconds: number
): Promise<string> {
  return hmacSha256Base64Url(
    provisioningKeyBase64,
    provisionRequestMessage(installId, issuedAtSeconds)
  );
}

export async function issueDeviceGrantToken(
  provisioningKeyBase64: string,
  installId: string
): Promise<string> {
  const signature = await hmacSha256Base64Url(
    provisioningKeyBase64,
    `${DEVICE_GRANT_PREFIX}${installId}`
  );
  return `${installId}.${signature}`;
}

export async function validateDeviceGrantToken(
  provisioningKeyBase64: string | undefined,
  presentedToken: string
): Promise<boolean> {
  if (!provisioningKeyBase64) return false;
  const dot = presentedToken.indexOf(".");
  if (dot <= 0 || dot >= presentedToken.length - 1) return false;
  const installId = presentedToken.slice(0, dot);
  const signature = presentedToken.slice(dot + 1);
  if (!isValidInstallId(installId) || signature.length < 16) return false;
  const expected = await hmacSha256Base64Url(
    provisioningKeyBase64,
    `${DEVICE_GRANT_PREFIX}${installId}`
  );
  return constantTimeEqual(expected, signature);
}

export function isValidGrantProvisionRequest(value: unknown): value is GrantProvisionRequest {
  if (!value || typeof value !== "object") return false;
  const o = value as Record<string, unknown>;
  if (typeof o.installId !== "string" || !isValidInstallId(o.installId)) return false;
  if (typeof o.issuedAtSeconds !== "number" || !Number.isFinite(o.issuedAtSeconds)) return false;
  if (o.issuedAtSeconds <= 0) return false;
  return true;
}

export async function validateGrantProvisionAuthorization(
  provisioningKeyBase64: string | undefined,
  authHeader: string | null,
  request: GrantProvisionRequest,
  nowSeconds: number
): Promise<GrantProvisionValidationResult> {
  if (!provisioningKeyBase64) {
    return { ok: false, status: 500, reason: "relay client provisioning is not configured" };
  }
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
  if (nowSeconds < request.issuedAtSeconds - PROVISION_MAX_SKEW_SECONDS) {
    return { ok: false, status: 403, reason: "provision request issued in the future" };
  }
  if (nowSeconds - request.issuedAtSeconds > PROVISION_MAX_SKEW_SECONDS) {
    return { ok: false, status: 403, reason: "provision request expired" };
  }
  const expected = await issueProvisionRequestSignature(
    provisioningKeyBase64,
    request.installId,
    request.issuedAtSeconds
  );
  if (!constantTimeEqual(expected, presented)) {
    return { ok: false, status: 403, reason: "provision authorization mismatch" };
  }
  return { ok: true, request };
}

export async function checkProvisionRateLimit(
  kv: KVNamespace | undefined,
  installId: string,
  nowSeconds: number
): Promise<GrantProvisionRateLimitResult> {
  if (!kv) return { ok: true };
  const key = `${PROVISION_RATE_LIMIT_PREFIX}${installId}`;
  const raw = await kv.get(key);
  let count = 0;
  let windowStart = nowSeconds;
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as { count?: number; windowStart?: number };
      if (
        typeof parsed.count === "number" &&
        typeof parsed.windowStart === "number" &&
        nowSeconds - parsed.windowStart < PROVISION_RATE_LIMIT_WINDOW_SECONDS
      ) {
        count = parsed.count;
        windowStart = parsed.windowStart;
      }
    } catch {
      // Treat malformed KV rows as a fresh window.
    }
  }
  if (count >= PROVISION_RATE_LIMIT_MAX) {
    return { ok: false, status: 429, reason: "provision rate limit exceeded" };
  }
  await kv.put(
    key,
    JSON.stringify({ count: count + 1, windowStart }),
    { expirationTtl: PROVISION_RATE_LIMIT_WINDOW_SECONDS }
  );
  return { ok: true };
}
