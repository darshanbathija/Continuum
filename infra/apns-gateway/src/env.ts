// Worker env binding shape. Mirrors wrangler.toml + the `wrangler secret put`
// secrets enumerated in ROTATION.md.

export interface Env {
  // ---- KV namespaces ----
  /** 90-day TTL audit trail. Entry shape in audit-log.ts. */
  APNS_AUDIT_LOG: KVNamespace;
  /** Per verified sender identity hourly counter. Key = `rl:<subjectHash>:<hourBucket>`. */
  APNS_RATE_LIMIT: KVNamespace;
  /**
   * Hashed-device-token → pairing-session-id registry (codex #5 tenant
   * binding). Key = `dt:<deviceTokenHash>`. Value = JSON `{ sessionId,
   * createdAt, lastSeenAt }`.
   */
  APNS_DEVICE_TOKENS: KVNamespace;

  // ---- Non-secret vars (see wrangler.toml [vars]) ----
  ENVIRONMENT: "development" | "staging" | "production" | "canary";
  LOG_LEVEL: "debug" | "info" | "warn" | "error";
  RATE_LIMIT_PER_HOUR: string;
  APNS_BEARER_TTL_SECONDS: string;
  APNS_ENDPOINT: string;
  TOPIC_ENV: "sandbox" | "production";
  APNS_DISABLED: string;
  DEVICE_TOKEN_TTL_SECONDS: string;
  AUDIT_LOG_TTL_SECONDS: string;
  P8_MAX_AGE_SECONDS: string;

  // ---- Secrets (set via `wrangler secret put`) ----
  APNS_P8_KEY: string;
  /** Unix-seconds string. CI rotation-drill job checks against P8_MAX_AGE_SECONDS. */
  APNS_P8_ISSUED_AT: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC_PRODUCTION: string;
  APNS_TOPIC_SANDBOX: string;
  /**
   * Shared HMAC key with the E2 relay Worker. Used to derive per-pairing
   * bearer tokens (see design doc §4.1 per-peer tokens) and to verify the
   * opt-out signature. 32 random bytes, base64.
   */
  RELAY_BEARER_SIGNING_KEY: string;
}

export function isKillSwitchOn(env: Env): boolean {
  // Treat any truthy-looking string as "on". Operator can flip via either
  // `wrangler secret put APNS_DISABLED --value true` or by changing the
  // non-secret var in wrangler.toml + redeploy.
  const v = (env.APNS_DISABLED ?? "false").toLowerCase().trim();
  return v === "true" || v === "1" || v === "on" || v === "yes";
}

export function rateLimitPerHour(env: Env): number {
  const n = Number.parseInt(env.RATE_LIMIT_PER_HOUR ?? "60", 10);
  return Number.isFinite(n) && n > 0 ? n : 60;
}

export function bearerTtlSeconds(env: Env): number {
  const n = Number.parseInt(env.APNS_BEARER_TTL_SECONDS ?? "300", 10);
  return Number.isFinite(n) && n > 0 ? n : 300;
}

export function deviceTokenTtlSeconds(env: Env): number {
  const n = Number.parseInt(env.DEVICE_TOKEN_TTL_SECONDS ?? "7776000", 10);
  return Number.isFinite(n) && n > 0 ? n : 7776000;
}

export function auditLogTtlSeconds(env: Env): number {
  const n = Number.parseInt(env.AUDIT_LOG_TTL_SECONDS ?? "7776000", 10);
  return Number.isFinite(n) && n > 0 ? n : 7776000;
}

export function p8MaxAgeSeconds(env: Env): number {
  const n = Number.parseInt(env.P8_MAX_AGE_SECONDS ?? "7776000", 10);
  return Number.isFinite(n) && n > 0 ? n : 7776000;
}
