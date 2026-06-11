// Test helpers shared across vitest specs. Generates fresh token pairs and
// drives WebSocket clients against SELF (the main Worker).

import { SELF } from "cloudflare:test";
import {
  issueSessionCreationSignature,
  type SessionAuthBundle,
} from "../src/auth";

export const TEST_RELAY_OPERATOR_SIGNING_KEY =
  "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
export const TEST_RELAY_CREATION_GRANT_TOKEN = "test-relay-grant-token";
export const TEST_RELAY_CLIENT_PROVISIONING_KEY =
  "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
export const TEST_RELAY_INSTALL_ID = "11111111-1111-4111-8111-111111111111";

/** A fresh, throwaway session id (suitable for the URL path). */
export function newSessionId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** A fresh 32-byte hex bearer token (same shape the design doc specifies). */
export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** SHA-256 hex of a raw bearer. */
export async function sha256Hex(input: string): Promise<string> {
  const enc = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", enc);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function newNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return base64UrlEncode(bytes);
}

export interface PairingTokens {
  sid: string;
  macTok: string;
  iosTok: string;
  macTokHash: string;
  iosTokHash: string;
  ttlSeconds: number;
  /** Base64-JSON bundle the first peer presents on `?bundle=`. */
  bundleParam: string;
}

export async function newPairing(ttlSecondsFromNow = 3600): Promise<PairingTokens> {
  const sid = newSessionId();
  const macTok = newToken();
  const iosTok = newToken();
  const macTokHash = await sha256Hex(macTok);
  const iosTokHash = await sha256Hex(iosTok);
  const ttlSeconds = Math.floor(Date.now() / 1000) + ttlSecondsFromNow;
  const creation = {
    issuedAtSeconds: Math.floor(Date.now() / 1000),
    nonce: newNonce(),
    signature: "placeholder",
  };
  const bundleObject: SessionAuthBundle = {
    macTokenHash: macTokHash,
    iosTokenHash: iosTokHash,
    ttlSeconds,
    creation,
  };
  bundleObject.creation.signature = await issueSessionCreationSignature(
    TEST_RELAY_OPERATOR_SIGNING_KEY,
    sid,
    bundleObject
  );
  const bundle = JSON.stringify(bundleObject);
  return {
    sid,
    macTok,
    iosTok,
    macTokHash,
    iosTokHash,
    ttlSeconds,
    bundleParam: btoa(bundle),
  };
}

/**
 * Open a WebSocket against the relay through SELF (the in-process Worker).
 * `bundleParam` is required ONLY for the first peer in a session; subsequent
 * connections omit it.
 */
export async function connectPeer(opts: {
  sid: string;
  token: string;
  bundleParam?: string;
}): Promise<{ socket: WebSocket; response: Response }> {
  const url = new URL(`https://relay.invalid/v1/relay/sessions/${opts.sid}/connect`);
  if (opts.bundleParam) {
    url.searchParams.set("bundle", opts.bundleParam);
  }
  const response = await SELF.fetch(url.toString(), {
    headers: {
      upgrade: "websocket",
      "sec-websocket-protocol": `bearer.${opts.token}`,
    },
  });
  if (!response.webSocket) {
    return { response, socket: null as unknown as WebSocket };
  }
  const ws = response.webSocket;
  ws.accept();
  return { socket: ws, response };
}

/** Subscribe to ws message events; returns an array that the caller can poll. */
export function collectMessages(ws: WebSocket): { received: Array<string | ArrayBuffer>; close: () => void } {
  const received: Array<string | ArrayBuffer> = [];
  const handler = (event: MessageEvent) => {
    if (typeof event.data === "string") {
      received.push(event.data);
    } else if (event.data instanceof ArrayBuffer) {
      received.push(event.data);
    } else {
      // Blob in test env — coerce. miniflare gives ArrayBuffer though.
      received.push(event.data as ArrayBuffer);
    }
  };
  ws.addEventListener("message", handler);
  return {
    received,
    close: () => ws.removeEventListener("message", handler),
  };
}

/** Wait until the predicate returns truthy or the timeout fires. */
export async function waitFor<T>(
  fn: () => T | undefined,
  { timeoutMs = 2000, intervalMs = 5 }: { timeoutMs?: number; intervalMs?: number } = {}
): Promise<T> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const v = fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`waitFor timed out after ${timeoutMs}ms`);
}

/** Build a wire-shape header text (matches src/envelope.ts serialization). */
export function makeHeader(opts: { from: "mac" | "ios"; type: "handshake" | "ciphertext" | "control" }): string {
  return JSON.stringify({ v: 1, from: opts.from, type: opts.type });
}

/** Pre-built opaque body bytes for tests (the relay never decodes these). */
export function makeOpaqueBody(label: string): Uint8Array {
  return new TextEncoder().encode(`OPAQUE:${label}`);
}
