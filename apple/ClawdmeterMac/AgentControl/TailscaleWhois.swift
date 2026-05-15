import Foundation
import OSLog

private let whoisLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TailscaleWhois")

/// Tailscale identity gating for non-loopback peers.
///
/// Shells out to `/opt/homebrew/bin/tailscale whois --json <peer-ip:port>`
/// (E4 path fix from Codex eng-round Round 1 — original plan had
/// `/usr/local/bin/tailscale` which is wrong on Apple Silicon Homebrew).
///
/// Per Codex eng-round Medium: whois failure or unknown peer = DENY
/// (fail closed), not unknown-allow. The accept-handler that calls this
/// rejects any connection where `userLoginName(for:)` returns nil.
///
/// Per E6: results are cached by IP for 60s — tailscale CLI startup is
/// ~50ms; uncached every-request would compound on busy iPhone polling.
public actor TailscaleWhois {

    public static let shared = TailscaleWhois()

    private struct CacheEntry {
        let loginName: String?  // nil = whois failed (deny)
        let cachedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 60

    /// Cached tailscale binary path (resolved at first use; we don't
    /// re-probe per call).
    private var tailscaleBinary: String?

    public init() {}

    /// Returns the Tailscale login (e.g. `"darshan.bathija@gmail.com"`) for
    /// a peer's IP, or `nil` if the peer is unknown / whois failed.
    ///
    /// - Parameter peerAddress: the connection's remote endpoint string
    ///   (`"100.91.212.32:53412"` or just `"100.91.212.32"`).
    public func userLoginName(for peerAddress: String) async -> String? {
        // Strip port if present — whois only takes an IP.
        let ip = peerAddress.split(separator: ":").first.map(String.init) ?? peerAddress

        if let cached = cache[ip], Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            return cached.loginName
        }

        let login = await performWhois(ip: ip)
        cache[ip] = CacheEntry(loginName: login, cachedAt: Date())
        return login
    }

    /// Force-invalidate the cache. Useful when the daemon detects a network
    /// change (sleep/wake, Tailscale restart).
    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Whois shell-out

    private func performWhois(ip: String) async -> String? {
        if tailscaleBinary == nil {
            tailscaleBinary = ShellRunner.locateBinary("tailscale")
        }
        guard let binary = tailscaleBinary else {
            whoisLogger.error("tailscale binary not found on PATH; whois fails closed (DENY)")
            return nil
        }

        do {
            let result = try await ShellRunner.shared.run(
                executable: binary,
                arguments: ["whois", "--json", ip],
                timeout: 5
            )
            guard result.exitStatus == 0 else {
                whoisLogger.debug("whois \(ip, privacy: .public) exit=\(result.exitStatus): \(result.stderrString, privacy: .public)")
                return nil
            }
            return Self.parseLoginName(from: result.stdout)
        } catch {
            whoisLogger.warning("whois \(ip, privacy: .public) shell failed: \(error.localizedDescription, privacy: .public); fail closed")
            return nil
        }
    }

    /// Parse `tailscale whois --json` output for the user's login name.
    /// Format (as of Tailscale 1.98.x):
    /// ```
    /// {
    ///   "Node": { "Name": "darshans-macbook-pro.tail87a721.ts.net.", ... },
    ///   "UserProfile": {
    ///     "ID": 300036349076449,
    ///     "LoginName": "darshan.bathija@gmail.com",
    ///     "DisplayName": "Darshan Bathija",
    ///     ...
    ///   }
    /// }
    /// ```
    static func parseLoginName(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let userProfile = json["UserProfile"] as? [String: Any] else {
            return nil
        }
        return userProfile["LoginName"] as? String
    }
}
