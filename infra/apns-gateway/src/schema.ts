// Hand-rolled request schema validation. No zod — we want zero runtime deps
// in the Worker bundle (cold-start budget + bundle size).
//
// Schemas mirror the design doc §4.4 APNSRequest shape but normalized to the
// over-the-wire JSON the Mac daemon actually POSTs. Per the plan: the body
// shape is `{ deviceToken, encryptedPayload, topic }`. We accept that
// surface plus the audit fields (sessionId for tenant binding, ts for rate
// limit, senderMacFingerprint for audit) the design doc requires.

import type { Env } from "./env.js";

/** Successful validation result. */
export interface PushRequest {
  /** Raw APNS device token (64 hex chars). Never persisted; hashed-only. */
  readonly deviceToken: string;
  /** Opaque encrypted payload. The Worker NEVER decrypts this. */
  readonly encryptedPayload: string;
  /** APNS topic. Must match the configured TOPIC_PRODUCTION/SANDBOX. */
  readonly topic: string;
  /** Pairing session id (codex #5 tenant binding). */
  readonly sessionId: string;
  /** Mac sender fingerprint for audit log (SHA-256 of pairing pubkey). */
  readonly senderMacFingerprint: string;
  /** Optional APNS priority. 10 = immediate; 5 = power-conscious. */
  readonly priority?: 5 | 10;
  /** Optional APNS push type. Defaults to "alert". */
  readonly pushType?: "alert" | "background" | "voip" | "complication";
  /** Optional APNS-Collapse-ID. */
  readonly collapseId?: string;
  /** Optional APNS expiration (epoch seconds). 0 = APNS chooses. */
  readonly expiration?: number;
}

export interface OptOutRequest {
  readonly deviceToken: string;
  /**
   * HMAC-SHA256(RELAY_BEARER_SIGNING_KEY, deviceToken + ":" + sessionId).
   * Proves the caller knows the session-bound signing material without
   * leaking the bearer itself.
   */
  readonly signature: string;
  readonly sessionId: string;
}

export type ValidationResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string; field?: string };

const HEX_64 = /^[0-9a-fA-F]{64}$/;
const HEX_ANY = /^[0-9a-fA-F]+$/;
const TOPIC_RE = /^[a-zA-Z0-9._-]{1,200}$/;
const SESSION_ID_RE = /^[A-Za-z0-9_-]{8,128}$/;
// Base64URL or base64. Allow both; APNS is strict but the encrypted blob
// is opaque to us — leave Apple to reject if it's malformed (it'd be the
// iPhone that fails to decrypt, not APNS itself).
const B64_ANY = /^[A-Za-z0-9+/=_-]+$/;

const MAX_ENCRYPTED_PAYLOAD_LEN = 3500; // APNS hard cap is 4KB; reserve some.
const MAX_COLLAPSE_ID_LEN = 64;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function asString(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

export function validatePushRequest(
  body: unknown,
  env: Env,
): ValidationResult<PushRequest> {
  if (!isRecord(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }

  const deviceToken = asString(body.deviceToken);
  if (!deviceToken) {
    return { ok: false, error: "deviceToken is required (string)", field: "deviceToken" };
  }
  if (!HEX_64.test(deviceToken)) {
    return { ok: false, error: "deviceToken must be 64 hex chars", field: "deviceToken" };
  }

  const encryptedPayload = asString(body.encryptedPayload);
  if (!encryptedPayload) {
    return { ok: false, error: "encryptedPayload is required (string)", field: "encryptedPayload" };
  }
  if (encryptedPayload.length > MAX_ENCRYPTED_PAYLOAD_LEN) {
    return {
      ok: false,
      error: `encryptedPayload exceeds ${MAX_ENCRYPTED_PAYLOAD_LEN} chars`,
      field: "encryptedPayload",
    };
  }
  if (!B64_ANY.test(encryptedPayload)) {
    return {
      ok: false,
      error: "encryptedPayload must be base64/base64url",
      field: "encryptedPayload",
    };
  }

  const topic = asString(body.topic);
  if (!topic) {
    return { ok: false, error: "topic is required (string)", field: "topic" };
  }
  if (!TOPIC_RE.test(topic)) {
    return { ok: false, error: "topic has invalid characters", field: "topic" };
  }
  // Operator-configured topic must match exactly. Prevents spoofing pushes
  // under a different bundle id (codex #5 abuse prevention).
  const expectedTopic =
    env.TOPIC_ENV === "production" ? env.APNS_TOPIC_PRODUCTION : env.APNS_TOPIC_SANDBOX;
  if (expectedTopic && topic !== expectedTopic) {
    return {
      ok: false,
      error: `topic does not match operator-configured ${env.TOPIC_ENV} topic`,
      field: "topic",
    };
  }

  const sessionId = asString(body.sessionId);
  if (!sessionId) {
    return { ok: false, error: "sessionId is required (string)", field: "sessionId" };
  }
  if (!SESSION_ID_RE.test(sessionId)) {
    return { ok: false, error: "sessionId has invalid characters", field: "sessionId" };
  }

  const senderMacFingerprint = asString(body.senderMacFingerprint);
  if (!senderMacFingerprint) {
    return {
      ok: false,
      error: "senderMacFingerprint is required (string)",
      field: "senderMacFingerprint",
    };
  }
  if (!HEX_ANY.test(senderMacFingerprint) || senderMacFingerprint.length !== 64) {
    return {
      ok: false,
      error: "senderMacFingerprint must be 64 hex chars (SHA-256 of pairing pubkey)",
      field: "senderMacFingerprint",
    };
  }

  let priority: 5 | 10 | undefined;
  if (body.priority !== undefined) {
    if (body.priority !== 5 && body.priority !== 10) {
      return { ok: false, error: "priority must be 5 or 10", field: "priority" };
    }
    priority = body.priority;
  }

  let pushType: PushRequest["pushType"];
  if (body.pushType !== undefined) {
    const pt = asString(body.pushType);
    if (pt !== "alert" && pt !== "background" && pt !== "voip" && pt !== "complication") {
      return { ok: false, error: "pushType is invalid", field: "pushType" };
    }
    pushType = pt;
  }

  let collapseId: string | undefined;
  if (body.collapseId !== undefined) {
    const c = asString(body.collapseId);
    if (!c) {
      return { ok: false, error: "collapseId must be string", field: "collapseId" };
    }
    if (c.length > MAX_COLLAPSE_ID_LEN) {
      return {
        ok: false,
        error: `collapseId exceeds ${MAX_COLLAPSE_ID_LEN} chars`,
        field: "collapseId",
      };
    }
    collapseId = c;
  }

  let expiration: number | undefined;
  if (body.expiration !== undefined) {
    if (typeof body.expiration !== "number" || !Number.isFinite(body.expiration) || body.expiration < 0) {
      return { ok: false, error: "expiration must be a non-negative number", field: "expiration" };
    }
    expiration = Math.floor(body.expiration);
  }

  return {
    ok: true,
    value: {
      deviceToken,
      encryptedPayload,
      topic,
      sessionId,
      senderMacFingerprint,
      priority,
      pushType,
      collapseId,
      expiration,
    },
  };
}

export function validateOptOutRequest(body: unknown): ValidationResult<OptOutRequest> {
  if (!isRecord(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const deviceToken = asString(body.deviceToken);
  if (!deviceToken || !HEX_64.test(deviceToken)) {
    return { ok: false, error: "deviceToken must be 64 hex chars", field: "deviceToken" };
  }
  const signature = asString(body.signature);
  if (!signature || !B64_ANY.test(signature) || signature.length < 16) {
    return { ok: false, error: "signature is required (base64 HMAC)", field: "signature" };
  }
  const sessionId = asString(body.sessionId);
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) {
    return { ok: false, error: "sessionId is required", field: "sessionId" };
  }
  return { ok: true, value: { deviceToken, signature, sessionId } };
}
