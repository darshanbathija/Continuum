import Foundation
import Combine
import OSLog
import CryptoKit
import ClawdmeterShared

private let iosPairingLogger = Logger(subsystem: "com.clawdmeter.ios", category: "RelayPairing")

/// E7 iOS-side state machine + persistence for relay pairing.
///
/// Drives:
///   - `unpaired → scanning → keyExchanged → readyButNotConnected`
///   - bundle parsing + validation (rejects expired TTL, mismatched
///     tokens, hostile relay URLs)
///   - X25519 keypair generation + HKDF-SHA256 key derivation
///   - persistence to `RelayPairingStore` (Application Support + Keychain)
///
/// Per the E7 task spec: this does NOT actually connect to the relay
/// (E4 will). The service stops at `readyButNotConnected` once the
/// derived key is persisted. The future `IOSRelayClient` (E4) will
/// observe `.readyButNotConnected → .connected`.
@MainActor
public final class IOSRelayPairingService: ObservableObject {

    public static let shared = IOSRelayPairingService()

    @Published public private(set) var phase: RelayPairingPhase = .unpaired
    @Published public private(set) var summary: RelayPairingSummary = .initial
    @Published public private(set) var lastError: String?

    private let store: RelayPairingStore
    /// Ephemeral X25519 keypair for the most recent scan. Held in memory
    /// only — the derived K is what we persist, per §5b. Nil between
    /// scans / after `reset()`.
    private var keypair: RelayPairingKeyPair?

    public init(store: RelayPairingStore = .shared) {
        self.store = store
        // On launch, restore the phase from persisted state. If a record
        // exists we go straight to `.readyButNotConnected`; if not we
        // start `.unpaired`.
        if let record = store.loadRecord() {
            self.phase = .readyButNotConnected
            self.summary = Self.makeSummary(for: record, phase: .readyButNotConnected)
            iosPairingLogger.info("Restored persisted pairing (sid=\(record.sid.prefix(8))…)")
        }
    }

    // MARK: - Public API

    /// Called by `PairingScanView` when the user opens the camera. Moves
    /// phase to `.scanning`.
    public func beginScanning() {
        lastError = nil
        phase = .scanning
        iosPairingLogger.info("Pairing scanner opened — phase=.scanning")
    }

    /// Called by the QR scanner (or paste-URL sheet) with a scanned URL
    /// string. Returns true if the URL parsed + the key was derived +
    /// stored; false (with `lastError` set) otherwise.
    @discardableResult
    public func handleScannedURL(_ urlString: String) -> Bool {
        guard let bundle = RelayPairingBundle.decode(fromURL: urlString) else {
            lastError = "Not a valid Clawdmeter pairing QR (expected `clawdmeter-pair://v1/…`)."
            iosPairingLogger.warning("Scan rejected: bundle decode failed")
            return false
        }
        return apply(bundle: bundle)
    }

    /// Apply a successfully-decoded bundle. Derives K, persists, and
    /// transitions to `.readyButNotConnected`.
    @discardableResult
    public func apply(bundle: RelayPairingBundle) -> Bool {
        let pair = RelayPairingKeyPair()
        let derivedKey: Data
        do {
            derivedKey = try pair.deriveSharedKey(
                theirPublicKeyBase64URL: bundle.ecdhPub,
                sessionId: bundle.sid
            )
        } catch {
            lastError = "Failed to derive shared key: \(error.localizedDescription)"
            iosPairingLogger.error("ECDH derivation failed: \(error.localizedDescription)")
            phase = .unpaired
            return false
        }

        let now = UInt64(Date().timeIntervalSince1970)
        let record = RelayPairingRecord(
            sid: bundle.sid,
            macTok: bundle.macTok,
            iosTok: bundle.iosTok,
            theirEcdhPublicKeyBase64URL: bundle.ecdhPub,
            ourEcdhPublicKeyBase64URL: pair.publicKeyBase64URL,
            derivedSymmetricKeyBase64URL: RelayPairingBase64URL.encode(derivedKey),
            ttl: bundle.ttl,
            relayUrl: bundle.relayUrl,
            pairedAtUnixSeconds: now
        )
        do {
            try store.save(record: record, symmetricKey: derivedKey)
        } catch {
            lastError = "Failed to persist pairing: \(error.localizedDescription)"
            iosPairingLogger.error("Persist failed: \(error.localizedDescription)")
            phase = .unpaired
            return false
        }

        self.keypair = pair
        self.lastError = nil
        // §5b: the moment we derived K, both halves of the X25519 are
        // mutually consistent (assuming the QR was valid). E4 will pick
        // up `.readyButNotConnected` and dial the relay.
        self.phase = .readyButNotConnected
        self.summary = Self.makeSummary(for: record, phase: phase)

        iosPairingLogger.info("Pairing applied — sid=\(bundle.sid.prefix(8))…, keyFp=\(self.summary.keyFingerprintPrefix ?? "n/a")")
        return true
    }

    /// "Forget pairing" — clears the record + Keychain key and returns
    /// to `.unpaired`.
    public func reset() {
        store.clear()
        keypair = nil
        phase = .unpaired
        summary = .initial
        lastError = nil
        iosPairingLogger.info("iOS pairing state reset to .unpaired")
    }

    // MARK: - Read-only accessors

    public var hasActivePairing: Bool {
        phase == .keyExchanged || phase == .readyButNotConnected
    }

    public var currentRecord: RelayPairingRecord? {
        store.loadRecord()
    }

    // MARK: - Summary helper

    private static func makeSummary(for record: RelayPairingRecord, phase: RelayPairingPhase) -> RelayPairingSummary {
        let now = UInt64(Date().timeIntervalSince1970)
        let remaining = record.ttl > now ? Int(record.ttl - now) : 0
        var fingerprint: String?
        if let keyB64 = record.derivedSymmetricKeyBase64URL,
           let keyBytes = RelayPairingBase64URL.decode(keyB64) {
            fingerprint = Self.shortFingerprint(of: keyBytes)
        }
        return RelayPairingSummary(
            phase: phase,
            sessionIdPrefix: String(record.sid.prefix(8)),
            keyFingerprintPrefix: fingerprint,
            secondsRemaining: remaining
        )
    }

    /// First 8 hex chars of SHA-256 over the symmetric key bytes. Safe
    /// to show in UI as a "compare these match" affordance for a future
    /// "trusted device" UX (design doc Open Question 1).
    private static func shortFingerprint(of keyBytes: Data) -> String {
        let hash = sha256(keyBytes)
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> [UInt8] {
        // Local helper to avoid the @testable import in the production
        // module. CryptoKit is already a transitive dep of
        // ClawdmeterShared so the symbol is available at link time.
        var hasher = CryptoKitSHA256()
        hasher.update(data: data)
        return hasher.finalizeBytes()
    }
}

// MARK: - CryptoKit shim

private struct CryptoKitSHA256 {
    private var hasher = SHA256()
    mutating func update(data: Data) { hasher.update(data: data) }
    func finalizeBytes() -> [UInt8] { Array(hasher.finalize()) }
}
