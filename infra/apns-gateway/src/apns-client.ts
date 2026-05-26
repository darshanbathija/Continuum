// APNS HTTP/2 client. ES256 JWT signing via Web Crypto + fetch() to Apple.
//
// Cloudflare Workers run all fetch() over HTTP/2 transparently when the
// target endpoint supports it, so the only Apple-specific work here is
// signing the JWT and constructing the right :path + headers.
//
// Reference: https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server

import {
  base64UrlEncode,
  importApnsPrivateKey,
} from "./crypto-utils.js";

const encoder = new TextEncoder();

export interface ApnsJwtParams {
  /** PEM-encoded .p8 contents (with or without BEGIN/END markers). */
  readonly p8Pem: string;
  /** 10-char Apple key id. */
  readonly keyId: string;
  /** 10-char Apple Team ID. */
  readonly teamId: string;
  /** Override "now" for deterministic tests. Seconds since epoch. */
  readonly nowSeconds?: number;
}

/**
 * Builds an ES256-signed APNS JWT.
 *
 * Apple requires the JWT to be no older than 1 hour. Workers reissue per-
 * request — the JWT signing cost is ~3-5ms under Web Crypto, well inside
 * our 50ms CPU budget. For high QPS we could cache the JWT in module scope
 * with a 50-minute TTL but the current traffic shape (plan-approval pushes,
 * not chat) doesn't justify the extra complexity.
 */
export async function buildApnsJwt(params: ApnsJwtParams): Promise<string> {
  const now = params.nowSeconds ?? Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: params.keyId, typ: "JWT" };
  const claims = { iss: params.teamId, iat: now };

  const headerB64 = base64UrlEncode(encoder.encode(JSON.stringify(header)));
  const claimsB64 = base64UrlEncode(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await importApnsPrivateKey(params.p8Pem);
  const sigBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput) as BufferSource,
  );
  const sig = base64UrlEncode(new Uint8Array(sigBuf));
  return `${signingInput}.${sig}`;
}

export type ApnsSendStatus =
  | { kind: "delivered"; apnsId: string | null }
  | { kind: "unregistered" } // 410 — caller must purge the token
  | { kind: "bad-token" } // 400 / 404 — invalid device token format
  | { kind: "rate-limited" } // 429 — Apple-side back-pressure
  | { kind: "server-error"; status: number; reason?: string }
  | { kind: "transport-error"; message: string };

export interface ApnsSendParams {
  readonly endpoint: string; // https://api.push.apple.com or sandbox
  readonly jwt: string;
  readonly deviceToken: string; // hex
  readonly topic: string;
  /** The opaque encrypted payload — wrapped into APNS `aps.alert.body`-like JSON. */
  readonly encryptedPayload: string;
  readonly priority?: 5 | 10;
  readonly pushType?: "alert" | "background" | "voip" | "complication";
  readonly collapseId?: string;
  readonly expiration?: number;
  /** Test-only: override the fetch impl (for vitest miniflare). */
  readonly fetchImpl?: typeof fetch;
}

/**
 * Build the APNS JSON body. Per the design doc the gateway NEVER sees
 * plaintext — the encryptedPayload is what the iPhone decrypts. We wrap it
 * under a custom key `cmEncrypted` so the iOS notification service
 * extension can pluck it out and decrypt before iOS renders the alert.
 *
 * For "background" push, no aps.alert; iOS routes to the bg handler.
 */
function buildApnsBody(p: ApnsSendParams): string {
  if (p.pushType === "background") {
    return JSON.stringify({
      aps: { "content-available": 1 },
      cmEncrypted: p.encryptedPayload,
    });
  }
  return JSON.stringify({
    aps: {
      alert: {
        // Placeholder strings — iOS notification service extension replaces
        // these with the decrypted title/body before display. Apple shows
        // these only if the NSE crashes.
        title: "Clawdmeter",
        body: "Plan update",
      },
      sound: "default",
      "mutable-content": 1,
    },
    cmEncrypted: p.encryptedPayload,
  });
}

export async function sendApnsPush(p: ApnsSendParams): Promise<ApnsSendStatus> {
  const url = `${p.endpoint.replace(/\/+$/, "")}/3/device/${p.deviceToken}`;
  const headers: Record<string, string> = {
    authorization: `bearer ${p.jwt}`,
    "apns-topic": p.topic,
    "apns-push-type": p.pushType ?? "alert",
    "content-type": "application/json",
  };
  if (p.priority !== undefined) headers["apns-priority"] = String(p.priority);
  if (p.collapseId) headers["apns-collapse-id"] = p.collapseId;
  if (p.expiration !== undefined) headers["apns-expiration"] = String(p.expiration);

  const body = buildApnsBody(p);
  const doFetch = p.fetchImpl ?? fetch;

  let resp: Response;
  try {
    resp = await doFetch(url, { method: "POST", headers, body });
  } catch (e) {
    return {
      kind: "transport-error",
      message: e instanceof Error ? e.message : String(e),
    };
  }

  const apnsId = resp.headers.get("apns-id");

  if (resp.status === 200) {
    return { kind: "delivered", apnsId };
  }
  if (resp.status === 410) {
    return { kind: "unregistered" };
  }
  if (resp.status === 400 || resp.status === 404) {
    // Try to surface Apple's "reason" for debugging.
    return { kind: "bad-token" };
  }
  if (resp.status === 429) {
    return { kind: "rate-limited" };
  }

  let reason: string | undefined;
  try {
    const text = await resp.text();
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === "object" && typeof parsed.reason === "string") {
      reason = parsed.reason;
    }
  } catch {
    // ignore
  }
  return { kind: "server-error", status: resp.status, reason };
}
