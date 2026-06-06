import Foundation
import CryptoKit

/// Track B — B3/B4: challenge-response auth for the Bonjour LAN-direct path.
///
/// The eng-review (D3) rejected sending the raw bearer token over plaintext LAN
/// HTTP: a same-WiFi attacker advertising `_clawdmeter._tcp` could harvest it
/// (= RCE on the `--dangerously-skip-permissions` daemon), or sniff it. Instead
/// every LAN exchange is bound to the pairing key `K` (derived at QR time):
///
/// 1. **Discovery fingerprint** — the Mac's Bonjour TXT carries
///    `fp = HMAC(K, "id")`; iOS verifies it against its stored pairing identity
///    before trusting the discovered host (defeats an impostor advertiser).
/// 2. **Handshake** — iOS sends a nonce; the Mac returns `HMAC(K, nonce)`,
///    proving it holds `K` (defeats a host that can't, even if it spoofed the
///    fingerprint by replaying the TXT).
/// 3. **Per-request MAC** — every request carries
///    `MAC = HMAC(K, version|role|sessionId|endpoint|method|path|bodyHash|nonce|ts)`.
///    The MAC binds role + endpoint + nonce + timestamp + version (CB-P1f) so a
///    captured frame can't be replayed against a different role/endpoint or
///    after the window. The raw token is NEVER on the wire.
///
/// All pure HMAC-SHA256 (CryptoKit) → fully unit-testable; the `NWListener` /
/// `NWBrowser` advertise/discover wiring lives in the platform targets.
public enum RelayLanAuth {

    /// Domain-separation tags so a MAC for one purpose can't be replayed as
    /// another. The unit separator (0x1F) can't appear in the base64url/hex
    /// fields it joins, so the canonical string is unambiguous.
    public static let protocolVersion = 1
    private static let sep = "\u{1f}"
    private static let idTag = "continuum-lan-id-v1"
    private static let challengeTag = "continuum-lan-challenge-v1"
    private static let requestTag = "continuum-lan-request-v1"

    public enum Role: String, Sendable { case mac, ios }

    /// Bonjour TXT fingerprint: `HMAC(K, "id")`, hex. Stable per pairing.
    public static func discoveryFingerprint(key: SymmetricKey) -> String {
        mac(key: key, message: idTag)
    }

    /// The Mac's proof it possesses `K`: `HMAC(K, "challenge" | nonce)`, hex.
    public static func challengeProof(key: SymmetricKey, nonce: String) -> String {
        mac(key: key, message: "\(challengeTag)\(sep)\(nonce)")
    }

    /// Canonical per-request string the MAC authenticates. Exposed so both
    /// sides build it identically.
    public static func requestCanonical(
        role: Role, sessionId: String, endpoint: String,
        method: String, path: String, body: Data?, nonce: String, timestamp: UInt64
    ) -> String {
        let bodyHash = Data(SHA256.hash(data: body ?? Data())).map { String(format: "%02x", $0) }.joined()
        return [
            requestTag, String(protocolVersion), role.rawValue, sessionId,
            endpoint, method, path, bodyHash, nonce, String(timestamp),
        ].joined(separator: sep)
    }

    /// Per-request MAC, hex.
    public static func requestMAC(
        key: SymmetricKey, role: Role, sessionId: String, endpoint: String,
        method: String, path: String, body: Data?, nonce: String, timestamp: UInt64
    ) -> String {
        mac(key: key, message: requestCanonical(
            role: role, sessionId: sessionId, endpoint: endpoint,
            method: method, path: path, body: body, nonce: nonce, timestamp: timestamp
        ))
    }

    /// Constant-time verification of a hex MAC over `message`.
    public static func verify(_ providedHex: String, message: String, key: SymmetricKey) -> Bool {
        guard let provided = Data(hexString: providedHex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided, authenticating: Data(message.utf8), using: key
        )
    }

    private static func mac(key: SymmetricKey, message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }
}

/// Server-side (Mac) verifier for LAN-direct requests: validates the per-request
/// MAC AND enforces freshness — a timestamp window + a single-use nonce cache —
/// so a captured request can't be replayed. Fail-closed: anything that doesn't
/// verify is rejected before any handler runs (B4). Not thread-safe; the daemon
/// owns one and touches it from its accept/dispatch context.
public final class RelayLanAuthVerifier {

    public enum Rejection: Equatable {
        case badMAC
        case staleTimestamp
        case replayedNonce
    }

    private let key: SymmetricKey
    private let window: TimeInterval
    private var seenNonces: [String: Date] = [:]

    public init(key: SymmetricKey, window: TimeInterval = 30) {
        self.key = key
        self.window = window
    }

    /// Verify a request. `now`/`requestTime` are seconds since 1970. Returns nil
    /// on success, or the reason on rejection. A verified request's nonce is
    /// consumed (single-use within the window).
    public func verify(
        role: RelayLanAuth.Role, sessionId: String, endpoint: String,
        method: String, path: String, body: Data?,
        nonce: String, timestamp: UInt64, mac providedHex: String,
        now: Date = Date()
    ) -> Rejection? {
        pruneExpired(now: now)
        let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
        // Timestamp freshness (allow small clock skew on both sides).
        let delta = nowSecs >= timestamp ? nowSecs - timestamp : timestamp - nowSecs
        guard Double(delta) <= window else { return .staleTimestamp }
        // MAC first (constant-time) so we don't leak nonce-state via timing.
        let canonical = RelayLanAuth.requestCanonical(
            role: role, sessionId: sessionId, endpoint: endpoint,
            method: method, path: path, body: body, nonce: nonce, timestamp: timestamp
        )
        guard RelayLanAuth.verify(providedHex, message: canonical, key: key) else { return .badMAC }
        // Single-use nonce within the window.
        guard seenNonces[nonce] == nil else { return .replayedNonce }
        seenNonces[nonce] = now
        return nil
    }

    public func pruneExpired(now: Date) {
        guard !seenNonces.isEmpty else { return }
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < window }
    }

    public var trackedNonceCount: Int { seenNonces.count }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo)); i += 2
        }
        self = Data(bytes)
    }
}
