// envelope.ts — Opaque envelope shape that the relay routes between peers.
//
// Per the design doc (docs/design/secure-relay-apns-2026-05-26.md §4.3), the
// relay sees ONLY ciphertext envelopes. The encryption is XChaCha20-Poly1305
// over an X25519+HKDF symmetric key the two peers derived directly. The relay
// has no key, cannot decrypt, and never logs the body — only routing metadata
// (sender role, frame count, byte length).
//
// NOTE on terminology: the original PR task brief mentioned "sealed-box"
// envelopes; the E1 design doc that ships in PR #123 specifies
// XChaCha20-Poly1305 AEAD on a derived symmetric key (the peers do their own
// ECDH first). The design doc is authoritative because the Mac/iOS clients
// (E3/E4) will implement against it. From the relay's perspective the
// distinction is immaterial — both shapes are "opaque bytes the relay forwards
// blind." The envelope shape below covers both schemes; the relay never
// inspects the inner bytes.

/**
 * Routing metadata for an envelope. The relay reads ONLY these fields; the
 * encrypted body is treated as an opaque blob.
 */
export type EnvelopeType =
  | "handshake" // ECDH public key exchange (plaintext bytes32, per §4.2)
  | "ciphertext" // XChaCha20-Poly1305 sealed payload (per §4.3)
  | "control"; // Heartbeat / keepalive (no body); peer-to-peer control frames

export interface EnvelopeHeader {
  /** Wire format version. Bumped when the envelope shape changes. */
  v: 1;
  /** Sender role — for routing fan-out (and for the audit log). */
  from: "mac" | "ios";
  /** Envelope category. The relay never inspects the body for any value here. */
  type: EnvelopeType;
}

/**
 * The whole envelope as it travels on the wire (binary WS frame). The body is
 * the raw bytes the sender wants delivered to the OTHER peer. The relay never
 * touches the body bytes — it just forwards.
 *
 * On the wire, the envelope is a single WebSocket message. To keep parsing
 * trivial across Swift + TypeScript, we use:
 *
 *   - Text frames for the header (a 1-line JSON header) followed by a binary
 *     frame for the body (the encrypted bytes).
 *
 * In practice, Cloudflare's WebSocket Hibernation API delivers each frame to
 * `webSocketMessage` separately. We pair them by sender ordering: the header
 * frame arrives, the relay caches it on a per-WebSocket attachment, then the
 * NEXT frame from that socket is treated as the body of that header.
 *
 * Control frames (heartbeat) have no body; the relay flushes the cached header
 * immediately on receipt if `type === "control"`.
 */
export interface Envelope {
  header: EnvelopeHeader;
  /** Raw bytes; the relay never inspects. Empty for `type === "control"`. */
  body: Uint8Array;
}

/** Parse the JSON header text. Returns null if malformed (caller MUST close). */
export function parseEnvelopeHeader(text: string): EnvelopeHeader | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const o = parsed as Record<string, unknown>;
  if (o.v !== 1) return null;
  if (o.from !== "mac" && o.from !== "ios") return null;
  if (o.type !== "handshake" && o.type !== "ciphertext" && o.type !== "control") return null;
  return { v: 1, from: o.from, type: o.type };
}

/** Cap on a single envelope body. iOS APNS-class payloads are 4 KiB; we allow
 * 64 KiB for chat / diff / completion frames, well below CF's 1 MiB cap. */
export const MAX_ENVELOPE_BODY_BYTES = 64 * 1024;

/** Cap on a header frame; keeps parsers tiny and DoS-resistant. */
export const MAX_ENVELOPE_HEADER_BYTES = 1024;

export function serializeEnvelopeHeader(header: EnvelopeHeader): string {
  // Deterministic key ordering — keeps test-vector bytes stable across runs.
  return JSON.stringify({ v: header.v, from: header.from, type: header.type });
}

/** Sanity-check envelope. Returns an error string if invalid, null if OK. */
export function validateEnvelope(env: Envelope): string | null {
  if (env.header.type === "control" && env.body.byteLength !== 0) {
    return "control envelope must have empty body";
  }
  if (env.body.byteLength > MAX_ENVELOPE_BODY_BYTES) {
    return `envelope body exceeds ${MAX_ENVELOPE_BODY_BYTES} byte cap`;
  }
  return null;
}

/** Audit-log entry shape — what the relay writes to RELAY_AUDIT_LOG KV.
 * Note: NEVER include body bytes, peer IPs (CF colo handles that separately
 * via Worker Analytics), or anything decryptable. */
export interface AuditEntry {
  /** ISO 8601 UTC. */
  ts: string;
  /** The Durable Object ID — uniquely identifies the pairing session. */
  sessionDoId: string;
  /** Counted envelopes by sender + type. NO bodies. */
  counts: {
    macHandshake: number;
    iosHandshake: number;
    macCiphertext: number;
    iosCiphertext: number;
    macControl: number;
    iosControl: number;
  };
  /** Total opaque bytes routed (sum of all bodies). For ops dashboards. */
  bytesRouted: number;
  /** Reason the session ended. */
  endReason: "idle-evict" | "ttl-expired" | "both-peers-closed" | "operator-evict";
}
