// E7: relay pairing state machine — shared by Mac + iPhone.
//
// Both peers walk the same sequence of states, just with different
// trigger inputs. The Mac drives it forward by generating the QR
// bundle; the iPhone drives it by scanning + key-deriving.
//
//     unpaired
//        │
//        ▼   (user taps "Pair iPhone" on Mac / opens scanner on iPhone)
//     generatingBundle  ── Mac only — keypair + tokens being minted
//        │
//        ▼   (Mac QR rendered → iPhone scan starts)
//     scanning          ── iPhone only — camera live, awaiting frame
//        │
//        ▼   (both sides have peer's public key + can derive K)
//     keyExchanged
//        │
//        ▼   (E3/E4 future PRs)
//     readyButNotConnected   ← we stop here for E7
//
// Per the E7 acceptance: state machine on both peers MUST reflect
// `unpaired → generatingBundle → scanning → keyExchanged →
// readyButNotConnected`. The final `connected` state is E3/E4's job.

import Foundation

/// Coarse phase the pairing UI surfaces on either peer. Stored in the
/// per-peer service (Mac: `RelayPairingService`; iOS: `IOSRelayPairingService`).
public enum RelayPairingPhase: String, Codable, Sendable, Equatable {
    /// No bundle has been generated (Mac) or scanned (iPhone). Initial
    /// state on a fresh install + the resting state after a "Forget"
    /// action.
    case unpaired

    /// MAC ONLY: a keypair + tokens are being minted; the QR isn't
    /// rendered yet. Usually <50ms but we model it explicitly so the
    /// UI can show a "Generating…" spinner instead of flashing the
    /// previous QR.
    case generatingBundle

    /// iOS ONLY: camera is live, no frame parsed yet. The Mac path skips
    /// this state and moves bundle → keyExchanged the moment the iPhone
    /// completes its half of the handshake (which we observe only when
    /// the actual relay round-trip ships — E3).
    case scanning

    /// Both peers hold the symmetric key K. Mac records this when the
    /// QR is displayed (its half of the handshake is committed). iPhone
    /// records this immediately after deriving K post-scan.
    case keyExchanged

    /// E7 terminal state. The pairing record is persisted; the relay
    /// hasn't been dialed yet. E3 (Mac) + E4 (iOS) transition this to
    /// a future `connected` once the WS open succeeds.
    case readyButNotConnected
}

/// Persisted-on-disk record of a completed pairing. iOS writes this
/// after a successful scan; Mac writes a sibling record when it
/// generates the bundle so a relaunch can replay the keypair (currently
/// we discard on relaunch — see §5b "ephemeral keys").
public struct RelayPairingRecord: Codable, Sendable, Equatable {

    public let sid: String
    public let macTok: String
    public let iosTok: String
    /// The peer's public key (i.e. the OTHER side's). On the iPhone this
    /// is the Mac's pubkey from the QR; on the Mac side, this would be
    /// populated only when E3/E4 deliver the iPhone's pubkey via the
    /// first relay frame.
    public let theirEcdhPublicKeyBase64URL: String?
    /// Our own public key — the one we sent over (Mac into the QR, iOS
    /// over the first relay frame). Saved so UI can render a fingerprint
    /// the user can compare for diagnostics.
    public let ourEcdhPublicKeyBase64URL: String
    /// Derived shared symmetric key (32 bytes), base64url. iOS persists
    /// it so the E4 client can seal frames immediately on relay open.
    public let derivedSymmetricKeyBase64URL: String?
    /// Absolute Unix seconds at which the session expires.
    public let ttl: UInt64
    public let relayUrl: String
    /// Wall-clock at which we entered `keyExchanged`. Used by UI for
    /// "Paired 2 min ago" + by E3/E4 for SLO tracking.
    public let pairedAtUnixSeconds: UInt64

    public init(
        sid: String,
        macTok: String,
        iosTok: String,
        theirEcdhPublicKeyBase64URL: String?,
        ourEcdhPublicKeyBase64URL: String,
        derivedSymmetricKeyBase64URL: String?,
        ttl: UInt64,
        relayUrl: String,
        pairedAtUnixSeconds: UInt64
    ) {
        self.sid = sid
        self.macTok = macTok
        self.iosTok = iosTok
        self.theirEcdhPublicKeyBase64URL = theirEcdhPublicKeyBase64URL
        self.ourEcdhPublicKeyBase64URL = ourEcdhPublicKeyBase64URL
        self.derivedSymmetricKeyBase64URL = derivedSymmetricKeyBase64URL
        self.ttl = ttl
        self.relayUrl = relayUrl
        self.pairedAtUnixSeconds = pairedAtUnixSeconds
    }
}

/// Operator-facing summary of the most recent pairing attempt. UI binds
/// to this in lieu of inspecting the record directly so we keep the
/// secret material out of accidentally-rendered debug overlays.
public struct RelayPairingSummary: Equatable, Sendable {
    public let phase: RelayPairingPhase
    /// First 8 chars of the sid — safe to show in support contexts.
    public let sessionIdPrefix: String?
    /// First 8 chars of the derived-key fingerprint (SHA-256 of K, first
    /// 8 hex chars). Lets the user "compare these short codes match" in
    /// future "trusted device" UX (Open Question 1).
    public let keyFingerprintPrefix: String?
    /// Seconds remaining on the TTL, computed from `Date.now`.
    public let secondsRemaining: Int?

    public init(
        phase: RelayPairingPhase,
        sessionIdPrefix: String? = nil,
        keyFingerprintPrefix: String? = nil,
        secondsRemaining: Int? = nil
    ) {
        self.phase = phase
        self.sessionIdPrefix = sessionIdPrefix
        self.keyFingerprintPrefix = keyFingerprintPrefix
        self.secondsRemaining = secondsRemaining
    }

    public static let initial = RelayPairingSummary(phase: .unpaired)
}
