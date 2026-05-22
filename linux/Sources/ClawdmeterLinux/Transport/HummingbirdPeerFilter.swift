import Foundation

/// Hummingbird middleware that enforces the same allowlist as Mac's
/// `AgentControlServer.acceptHandler`:
/// - `127.0.0.0/8`  (IPv4 loopback)
/// - `::1`          (IPv6 loopback)
/// - `100.64.0.0/10` (Tailscale CGNAT, IPv4)
/// - `fd7a:115c:a1e0::/48` (Tailscale ULA, IPv6)
///
/// Defense in depth: even with bearer-token auth, we don't want a public
/// IP scanning around on 21731 to be able to probe responses. Reject at
/// L4 before any byte of the request body is read.
///
/// Phase 3 build-out: actual Hummingbird middleware wiring under `#if os(Linux)`.
public struct HummingbirdPeerFilter: Sendable {

    public init() {}

    /// Returns `.allowed` if the peer IP matches an allowlisted range,
    /// `.denied` otherwise. Phase 3 hooks this into Hummingbird's
    /// `Middleware.handle(_:next:)` shape.
    public enum Decision: Sendable, Equatable {
        case allowed
        case denied(reason: String)
    }

    /// Check a peer IP (IPv4 dotted-quad or IPv6 colon-separated) against the
    /// allowlist. Phase 3 calls this from middleware; tested directly via
    /// `linux/Tests/.../Security/PeerFilterTests.swift` (D7).
    public static func decide(peerIP: String) -> Decision {
        // Audit P1 fix: on Linux dual-stack listeners (`::`), IPv4 peers
        // arrive as `::ffff:127.0.0.1` / `::ffff:100.64.x.y`. Stripping
        // the v4-mapped prefix BEFORE the prefix/range checks lets the
        // same IPv4 rules match — without this strip, every legitimate
        // pairing from loopback or Tailscale CGNAT was being rejected.
        var ip = peerIP
        let lowered = ip.lowercased()
        if lowered.hasPrefix("::ffff:") {
            ip = String(ip.dropFirst("::ffff:".count))
        }
        // IPv6 loopback
        if ip == "::1" {
            return .allowed
        }
        // IPv4 loopback (127/8)
        if ip.hasPrefix("127.") {
            return .allowed
        }
        // Tailscale CGNAT (100.64.0.0/10 → 100.64.x.x through 100.127.x.x)
        let octets = ip.split(separator: ".")
        if octets.count == 4, let first = Int(octets[0]), first == 100,
           let second = Int(octets[1]), second >= 64, second <= 127 {
            return .allowed
        }
        // Tailscale IPv6 ULA (fd7a:115c:a1e0::/48)
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0:") {
            return .allowed
        }
        return .denied(reason: "peer \(peerIP) not in allowlist (loopback / Tailscale CGNAT / Tailscale ULA)")
    }
}
