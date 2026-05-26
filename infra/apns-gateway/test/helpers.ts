// Test helpers — in-memory KV + .p8 fixture + bearer issuance.
//
// We hand-roll the KV stub instead of pulling in miniflare to keep the
// dev/test loop fast (cold install <1s) and avoid coupling tests to
// platform-emulator semantics. The KV interface used in src/ is a tiny
// subset of @cloudflare/workers-types' KVNamespace — easy to fake.

import type { Env } from "../src/env.js";
import { issueBearerToken } from "../src/auth.js";
import {
  base64UrlEncode,
  hmacSha256Base64,
} from "../src/crypto-utils.js";

interface KvEntry {
  value: string;
  expiresAt: number | null;
}

export class InMemoryKV {
  private store = new Map<string, KvEntry>();
  private now: () => number;

  constructor(now: () => number = () => Date.now() / 1000) {
    this.now = now;
  }

  // Use loose typing because the real KVNamespace surface is huge and we
  // only need a handful of methods. Tests cast InMemoryKV to KVNamespace.
  async get(
    key: string,
    _opts?: unknown,
  ): Promise<string | null> {
    const entry = this.store.get(key);
    if (!entry) return null;
    if (entry.expiresAt !== null && entry.expiresAt < this.now()) {
      this.store.delete(key);
      return null;
    }
    return entry.value;
  }

  async put(
    key: string,
    value: string,
    opts?: { expirationTtl?: number; expiration?: number },
  ): Promise<void> {
    let expiresAt: number | null = null;
    if (opts?.expirationTtl) expiresAt = this.now() + opts.expirationTtl;
    if (opts?.expiration) expiresAt = opts.expiration;
    this.store.set(key, { value, expiresAt });
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(opts?: { prefix?: string }): Promise<{
    keys: { name: string; expiration?: number }[];
    list_complete: true;
    cacheStatus: null;
  }> {
    const prefix = opts?.prefix ?? "";
    const keys: { name: string; expiration?: number }[] = [];
    for (const [name, entry] of this.store) {
      if (entry.expiresAt !== null && entry.expiresAt < this.now()) continue;
      if (name.startsWith(prefix)) {
        keys.push({
          name,
          ...(entry.expiresAt !== null ? { expiration: entry.expiresAt } : {}),
        });
      }
    }
    return { keys, list_complete: true, cacheStatus: null };
  }

  // Test-only accessor.
  rawEntries(): Map<string, KvEntry> {
    return this.store;
  }
}

/**
 * Test-only ES256 key pair. Generated once per process at module load.
 * The "p8" PEM is exported in pkcs8 + base64. The matching public key is
 * available for verifying signatures in tests if needed.
 */
let cachedKey: { p8Pem: string; issuedAt: number } | null = null;

async function generateTestP8Pem(): Promise<{ p8Pem: string; issuedAt: number }> {
  if (cachedKey) return cachedKey;
  // generateKey for ECDSA returns CryptoKeyPair; cast since the lib types
  // union it with single CryptoKey.
  const pair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const exported = (await crypto.subtle.exportKey(
    "pkcs8",
    pair.privateKey,
  )) as ArrayBuffer;
  const b64 = btoa(String.fromCharCode(...new Uint8Array(exported)));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----`;
  const issuedAt = Math.floor(Date.now() / 1000);
  cachedKey = { p8Pem: pem, issuedAt };
  return cachedKey;
}

const SIGNING_KEY_BYTES = new Uint8Array(32);
crypto.getRandomValues(SIGNING_KEY_BYTES);
const SIGNING_KEY_B64 = base64UrlEncode(SIGNING_KEY_BYTES);

const TEST_TOPIC = "com.clawdmeter.mac";

export interface MakeEnvOpts {
  killSwitch?: boolean;
  ratePerHour?: number;
  topicEnv?: "sandbox" | "production";
  p8IssuedAt?: number;
}

export async function makeEnv(opts: MakeEnvOpts = {}): Promise<Env> {
  const { p8Pem, issuedAt } = await generateTestP8Pem();
  return {
    APNS_AUDIT_LOG: new InMemoryKV() as unknown as KVNamespace,
    APNS_RATE_LIMIT: new InMemoryKV() as unknown as KVNamespace,
    APNS_DEVICE_TOKENS: new InMemoryKV() as unknown as KVNamespace,
    ENVIRONMENT: "development",
    LOG_LEVEL: "debug",
    RATE_LIMIT_PER_HOUR: String(opts.ratePerHour ?? 60),
    APNS_ENDPOINT: "https://api.sandbox.push.apple.com",
    TOPIC_ENV: opts.topicEnv ?? "sandbox",
    APNS_DISABLED: opts.killSwitch ? "true" : "false",
    DEVICE_TOKEN_TTL_SECONDS: "7776000",
    AUDIT_LOG_TTL_SECONDS: "7776000",
    P8_MAX_AGE_SECONDS: "7776000",
    APNS_P8_KEY: p8Pem,
    APNS_P8_ISSUED_AT: String(opts.p8IssuedAt ?? issuedAt),
    APNS_KEY_ID: "TESTKID123",
    APNS_TEAM_ID: "TESTTEAM01",
    APNS_TOPIC_PRODUCTION: "com.clawdmeter.iphone",
    APNS_TOPIC_SANDBOX: TEST_TOPIC,
    RELAY_BEARER_SIGNING_KEY: SIGNING_KEY_B64,
  };
}

const HEX = "0123456789abcdef";
export function makeDeviceToken(seed = 0): string {
  let out = "";
  for (let i = 0; i < 64; i++) out += HEX[(i + seed) % 16]!;
  return out;
}

export function makeFingerprint(seed = 0): string {
  let out = "";
  for (let i = 0; i < 64; i++) out += HEX[(i * 3 + seed) % 16]!;
  return out;
}

export function makeSessionId(suffix = "default"): string {
  return `sess_${suffix}_abcdef0123456789`;
}

export interface ValidPushBody {
  deviceToken: string;
  encryptedPayload: string;
  topic: string;
  sessionId: string;
  senderMacFingerprint: string;
  priority?: 5 | 10;
  pushType?: "alert" | "background" | "voip" | "complication";
  collapseId?: string;
  expiration?: number;
}

export function makePushBody(overrides: Partial<ValidPushBody> = {}): ValidPushBody {
  return {
    deviceToken: makeDeviceToken(),
    encryptedPayload: "dGVzdC1lbmNyeXB0ZWQtcGF5bG9hZA", // base64url
    topic: TEST_TOPIC,
    sessionId: makeSessionId(),
    senderMacFingerprint: makeFingerprint(),
    ...overrides,
  };
}

export async function authHeaderFor(env: Env, body: ValidPushBody): Promise<string> {
  const token = await issueBearerToken(env.RELAY_BEARER_SIGNING_KEY, {
    sessionId: body.sessionId,
    senderMacFingerprint: body.senderMacFingerprint,
  });
  return `Bearer ${token}`;
}

export async function optOutSignatureFor(
  env: Env,
  deviceToken: string,
  sessionId: string,
): Promise<string> {
  return await hmacSha256Base64(
    env.RELAY_BEARER_SIGNING_KEY,
    `optout:${sessionId}:${deviceToken}`,
  );
}

export const TEST_TOPIC_SANDBOX = TEST_TOPIC;

/**
 * Mock ExecutionContext used by tests. Workers ctx has waitUntil + passThroughOnException.
 */
export function makeCtx(): ExecutionContext {
  return {
    waitUntil() {},
    passThroughOnException() {},
    // Required field per @cloudflare/workers-types — `props` was added in
    // workers-types 4.x for Workers RPC. Tests don't use it.
    props: undefined,
  } as unknown as ExecutionContext;
}

/**
 * Replaces global fetch (which the apns-client calls) with a stub for the
 * duration of `fn`. The stub returns the next queued Response. Restored on
 * exit (including throw paths).
 */
export async function withMockedApnsFetch(
  queue: Array<{ status: number; body?: string; headers?: Record<string, string> }>,
  fn: () => Promise<void>,
): Promise<{ requests: { url: string; init: RequestInit }[] }> {
  const requests: { url: string; init: RequestInit }[] = [];
  const realFetch = globalThis.fetch;
  let idx = 0;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    requests.push({ url, init: init ?? {} });
    const next = queue[idx++];
    if (!next) {
      throw new Error("withMockedApnsFetch: ran out of queued responses");
    }
    return new Response(next.body ?? "", {
      status: next.status,
      headers: next.headers ?? {},
    });
  }) as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = realFetch;
  }
  return { requests };
}
