import Foundation
import OSLog
import Combine
import ClawdmeterShared

private let relayPairingLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RelayPairing")

/// E7 Mac-side state machine + bundle factory for relay pairing.
///
/// Owns:
///   - the ephemeral X25519 keypair the Mac generates per pairing
///   - the (sid, macTok, iosTok) tuple the Mac mints at QR time
///   - the persisted-for-this-process record so the QR can be redisplayed
///     without re-minting (re-minting would invalidate the iPhone's
///     already-scanned bundle)
///
/// Per the E7 task spec ("but DOES NOT actually connect to the relay (E3
/// will)") this service just GENERATES the bundle + shows the QR. The
/// actual relay WebSocket open lives in E3.
///
/// Per design doc §5b: the Mac's X25519 private key is held in process
/// memory only; it is never written to Keychain or disk. Relaunching
/// Clawdmeter invalidates the previous QR — the user must regenerate.
@MainActor
public final class RelayPairingService: ObservableObject {

    // MARK: - Observable state

    @Published public private(set) var phase: RelayPairingPhase = .unpaired

    /// The currently-active bundle. The QR view reads `bundleURL` off of
    /// this; nil while in `.unpaired` / `.generatingBundle`.
    @Published public private(set) var bundle: RelayPairingBundle?

    /// Encoded `clawdmeter-pair://v1/<base64>` URL of the current bundle,
    /// for both the QR generator and the "Copy to clipboard" fallback.
    @Published public private(set) var bundleURL: String?

    /// Operator-facing summary derived from the current state. UI binds
    /// to this so secret material never accidentally leaks into views.
    @Published public private(set) var summary: RelayPairingSummary = .initial

    /// The relay env the Mac currently targets. The Mac UI can flip this
    /// (defaults to `.staging` for E7).
    @Published public var environment: RelayEnvironment = .default {
        didSet {
            // Bundle is stale once the env changes — drop it. Next "Pair"
            // tap mints a fresh one against the new env.
            if environment != oldValue { reset() }
        }
    }

    // MARK: - Internal state

    /// Mac's ephemeral X25519 keypair. NOT persisted; new pairing → new
    /// keypair. Held until `reset()` or the service is dealloc'd.
    private var keypair: RelayPairingKeyPair?

    public init() {}

    // MARK: - Public API

    /// User tapped "Pair iPhone" on the Mac. Generates the bundle.
    ///
    /// Synchronous because all the work — keypair gen, token gen, JSON
    /// encode — is microsecond-scale. We deliberately do NOT call into
    /// the relay Worker here; per E7 scope, the bundle exists locally
    /// and the iPhone's first relay connect (E4) will tell the Worker
    /// what sessionId + token pair to expect via the `?bundle=` param
    /// (E2's first-peer-bootstrap, infra/relay/src/durable-object.ts).
    public func beginPairing() {
        phase = .generatingBundle
        relayPairingLogger.info("Beginning relay pairing bundle generation")

        let pair = RelayPairingKeyPair()
        let sid = RelayPairingMint.randomBase64URLToken()
        let macTok = RelayPairingMint.randomBase64URLToken()
        let iosTok = RelayPairingMint.randomBase64URLToken()
        // 15-min TTL per §5b. Persist as absolute Unix seconds so the
        // relay's server-side wall clock compare in §4.1 lines up.
        let ttl = UInt64(Date().timeIntervalSince1970) + 900
        let relayUrl = RelayEnvironment.resolvedRelayURL(env: environment)

        let bundle = RelayPairingBundle(
            sid: sid,
            macTok: macTok,
            iosTok: iosTok,
            ecdhPub: pair.publicKeyBase64URL,
            ttl: ttl,
            relayUrl: relayUrl
        )

        let urlString: String
        do {
            urlString = try bundle.encodeToURL()
        } catch {
            relayPairingLogger.error("Failed to encode bundle URL: \(error.localizedDescription)")
            self.phase = .unpaired
            return
        }

        self.keypair = pair
        self.bundle = bundle
        self.bundleURL = urlString
        // §5b "forward secrecy by construction" — the Mac's commitment
        // happens the moment it displays the bundle. The iPhone's half
        // (its derived K) is observed-but-not-known to us until E3/E4
        // bring the relay frame through. For UI purposes we mark the
        // Mac side `keyExchanged` to signal "QR is live and ready for
        // the iPhone to scan", then `readyButNotConnected` since the
        // socket itself is E3's job.
        self.phase = .readyButNotConnected
        self.refreshSummary()

        relayPairingLogger.info("Bundle minted (sid=\(bundle.sid.prefix(8))…, ttl=\(ttl))")
    }

    /// User tapped "Forget" / "Cancel pairing" — wipes the in-memory
    /// keypair + bundle. The QR view falls back to the empty state.
    public func reset() {
        keypair = nil
        bundle = nil
        bundleURL = nil
        phase = .unpaired
        summary = .initial
        relayPairingLogger.info("Relay pairing state reset to .unpaired")
    }

    // MARK: - Summary

    /// Refresh the operator-facing summary. Computes seconds-remaining
    /// from the bundle TTL.
    private func refreshSummary() {
        guard let bundle else {
            summary = .initial
            return
        }
        let now = UInt64(Date().timeIntervalSince1970)
        let remaining = bundle.ttl > now ? Int(bundle.ttl - now) : 0
        summary = RelayPairingSummary(
            phase: phase,
            sessionIdPrefix: String(bundle.sid.prefix(8)),
            keyFingerprintPrefix: nil, // requires iPhone's pubkey; unknown on Mac side in E7
            secondsRemaining: remaining
        )
    }

    // MARK: - Testing hooks

    /// For unit tests only: directly read the keypair to verify the
    /// derived key against the iPhone-side derivation.
    public var keypairForTesting: RelayPairingKeyPair? { keypair }
}
