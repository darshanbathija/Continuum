// Tiny Web Crypto helpers. Workers ship Web Crypto API; we use it for both
// the APNS JWT (ES256) and the device-token hashing + opt-out signature
// verification. No Node.js APIs.

const HEX = "0123456789abcdef";

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i]!;
    out += HEX[b >>> 4]! + HEX[b & 0x0f]!;
  }
  return out;
}

export function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) {
    throw new Error("hex string must have even length");
  }
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const hi = Number.parseInt(hex.substring(i * 2, i * 2 + 1), 16);
    const lo = Number.parseInt(hex.substring(i * 2 + 1, i * 2 + 2), 16);
    if (Number.isNaN(hi) || Number.isNaN(lo)) {
      throw new Error("invalid hex");
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export function base64Decode(b64: string): Uint8Array {
  // Accept either standard or url-safe base64.
  const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const textEncoder = new TextEncoder();

/** SHA-256(hex-string-decoded-as-bytes) → lowercase hex digest. */
export async function sha256HexOfHex(hex: string): Promise<string> {
  const bytes = hexToBytes(hex);
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return bytesToHex(new Uint8Array(digest));
}

/** SHA-256(string) → lowercase hex. */
export async function sha256HexOfString(input: string): Promise<string> {
  const bytes = textEncoder.encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return bytesToHex(new Uint8Array(digest));
}

/**
 * HMAC-SHA256 → base64. Key may be base64 (operator stores
 * RELAY_BEARER_SIGNING_KEY that way) or raw bytes.
 */
export async function hmacSha256Base64(keyBase64: string, message: string): Promise<string> {
  const keyBytes = base64Decode(keyBase64);
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, textEncoder.encode(message) as BufferSource);
  return base64UrlEncode(new Uint8Array(sig));
}

/**
 * Verifies the HMAC-SHA256 base64 signature against expected value. Constant-
 * time comparison to avoid timing side channels on the opt-out endpoint.
 */
export async function verifyHmacSha256Base64(
  keyBase64: string,
  message: string,
  presentedSignatureBase64: string,
): Promise<boolean> {
  const expected = await hmacSha256Base64(keyBase64, message);
  // Normalize to url-safe base64 then constant-time compare.
  const a = expected.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const b = presentedSignatureBase64
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Parses an APNS .p8 PEM string into a CryptoKey for ES256 signing. Accepts
 * either with or without BEGIN/END markers; the input comes from
 * `wrangler secret put` so operators may paste either form.
 */
export async function importApnsPrivateKey(p8Pem: string): Promise<CryptoKey> {
  const stripped = p8Pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const der = base64Decode(stripped);
  return await crypto.subtle.importKey(
    "pkcs8",
    der as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}
