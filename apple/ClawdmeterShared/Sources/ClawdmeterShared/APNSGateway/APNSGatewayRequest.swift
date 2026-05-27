// E6: wire-shape mirror of the E5 APNS gateway request schema.
//
// The Mac POSTs JSON to `<gateway>/push`; the Worker validates against
// `infra/apns-gateway/src/schema.ts:validatePushRequest`. We mirror the
// shape here so both sides stay in lockstep, and so the unit test path can
// exercise the actual JSON the Worker would see.

import Foundation

/// POST `<gateway>/push` body. Field names + casing mirror
/// `PushRequest` in `infra/apns-gateway/src/schema.ts:13`.
public struct APNSGatewayPushRequest: Codable, Sendable, Equatable {

    /// Raw APNS device token (64 hex chars). The Worker hashes this server-side
    /// before any persistence — codex #5 storage rule.
    public let deviceToken: String

    /// Base64-encoded XChaCha20-Poly1305 / ChaCha20-Poly1305 sealed body.
    /// The Worker NEVER decrypts; only the paired iPhone has the key.
    public let encryptedPayload: String

    /// APNS topic — `com.clawdmeter.iphone` in production. The Worker rejects
    /// any topic that doesn't match its operator-configured value
    /// (`APNS_TOPIC_PRODUCTION`/`APNS_TOPIC_SANDBOX`).
    public let topic: String

    /// Pairing session id (codex #5 tenant binding). First push registers
    /// the device token under this session; subsequent pushes must come
    /// from the SAME session or the Worker returns 403.
    public let sessionId: String

    /// 64 hex chars — SHA-256(Mac's pairing pubkey). Audit-only; the Worker
    /// validates the charset + length, then records it under the audit log.
    public let senderMacFingerprint: String

    /// APNS priority: 10 = immediate (default for plan-ready / permission
    /// prompt; we want the lock screen lit instantly), 5 = power-conscious.
    public let priority: Int?

    /// APNS push type. Default "alert"; "background" is reserved for the
    /// future silent-update path (E8).
    public let pushType: PushType?

    /// Optional APNS-Collapse-ID — APNS will fold same-collapse-id pushes
    /// into a single notification. Used by plan-ready when the same session
    /// emits a follow-up.
    public let collapseId: String?

    /// APNS-Expiration epoch seconds. 0 = APNS chooses. Default to
    /// `triggerAt + 60` for time-sensitive pushes so a stale plan-ready
    /// banner doesn't appear an hour later.
    public let expiration: UInt64?

    public init(
        deviceToken: String,
        encryptedPayload: String,
        topic: String,
        sessionId: String,
        senderMacFingerprint: String,
        priority: Int? = 10,
        pushType: PushType? = .alert,
        collapseId: String? = nil,
        expiration: UInt64? = nil
    ) {
        self.deviceToken = deviceToken
        self.encryptedPayload = encryptedPayload
        self.topic = topic
        self.sessionId = sessionId
        self.senderMacFingerprint = senderMacFingerprint
        self.priority = priority
        self.pushType = pushType
        self.collapseId = collapseId
        self.expiration = expiration
    }

    public enum PushType: String, Codable, Sendable {
        case alert
        case background
        case voip
        case complication
    }
}

/// 200/410 response shapes the Worker can return on `/push`.
public enum APNSGatewayPushResponse: Sendable {
    case delivered(apnsId: String?)
    case unregistered // 410 — the iPhone uninstalled the app or revoked
    case badToken
    case rateLimited(retryAfterSeconds: Int?)
    case unauthorized
    case forbidden(reason: String?)
    case schemaError(reason: String?, field: String?)
    case serverError(status: Int, reason: String?)
    case killSwitch
    case transportError(message: String)
}

/// DELETE `<gateway>/device-token` body. Mirrors `OptOutRequest` in
/// `infra/apns-gateway/src/schema.ts:34`.
public struct APNSGatewayOptOutRequest: Codable, Sendable, Equatable {

    public let deviceToken: String
    public let signature: String
    public let sessionId: String

    public init(deviceToken: String, signature: String, sessionId: String) {
        self.deviceToken = deviceToken
        self.signature = signature
        self.sessionId = sessionId
    }
}
