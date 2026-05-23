import Foundation
import Darwin

/// Resolves the address an iPhone or Apple Watch should use to reach this
/// Mac's pairing daemon. The shipped daemon binds to loopback + the
/// Tailscale CGNAT v4 range (100.64.0.0/10) + the Tailscale v6 prefix
/// (fd7a:115c:a1e0::/48). The pairing URL has to encode an address the
/// *phone* can route to — `127.0.0.1` only works for the iOS simulator
/// running on this Mac.
///
/// The previous resolver shelled out to `/opt/homebrew/bin/tailscale`
/// directly; when Tailscale wasn't installed via Homebrew (Mac App Store
/// build, Intel Mac on `/usr/local/bin`, manual install, etc.), the
/// process throw was swallowed and the URL silently fell back to
/// `127.0.0.1`. Phones never reached the Mac. This resolver reads the
/// interface address straight from `getifaddrs(3)` — no shell-out, no
/// path assumptions — and only falls back to the CLI for MagicDNS.
enum TailscaleHost {

    struct Resolved {
        let host: String
        let kind: Kind

        enum Kind {
            /// Tailscale v4 (100.64.0.0/10) from a local interface. Tunnel
            /// is up — pairing works.
            case tailscaleIPv4
            /// Tailscale v6 (fd7a:115c:a1e0::/48) from a local interface.
            /// `host` is bracketed for direct URL embedding. Tunnel up.
            case tailscaleIPv6
            /// MagicDNS name read from `tailscale status --json` while
            /// the backend is Running. Pairing works.
            case tailscaleDNS
            /// MagicDNS name is known but the Tailscale backend is not
            /// Running (signed-out, paused, or Stopped). The URL is
            /// correct for when the user turns Tailscale back on; we
            /// surface a banner so they know to flip it on.
            case tailscaleDNSBackendDown(state: String)
            /// Loopback fallback. Pairing won't work off this Mac. We
            /// don't fall back to Bonjour `.local` here because the
            /// daemon's peer filter (`AgentControlServer.isAllowedPeer`)
            /// rejects RFC1918 LAN addresses — only loopback + Tailscale.
            case loopback
        }

        var isRoutableOffMac: Bool {
            switch kind {
            case .tailscaleIPv4, .tailscaleIPv6, .tailscaleDNS:
                return true
            case .tailscaleDNSBackendDown, .loopback:
                return false
            }
        }
    }

    static func resolve() -> Resolved {
        // v16 MagicDNS preference. When the user opts into MagicDNS in
        // Settings → Pairing (default ON), we look up the tailnet hostname
        // first and only fall back to numeric addresses when MagicDNS is
        // unavailable or the Tailscale backend isn't running. Hostname
        // pairing is more robust across IP changes (sleep/wake, switching
        // networks) and is required for the future `clawdmeters://` TLS
        // scheme (TLS needs a hostname to match the Tailscale-issued cert).
        let preferMagicDNS = UserDefaults.standard.object(
            forKey: "clawdmeter.pairing.preferMagicDNS"
        ) as? Bool ?? true

        if preferMagicDNS, let dns = readTailscaleStatus() {
            if dns.backendState == "Running" {
                return Resolved(host: dns.dnsName, kind: .tailscaleDNS)
            }
            // Backend not running — fall through to numeric scan so the
            // user still gets a usable QR if their tunnel was up at some
            // point in the past and the interface IP is still bound.
            if let v4 = scanInterfaceForTailscaleIPv4() {
                return Resolved(host: v4, kind: .tailscaleIPv4)
            }
            if let v6 = scanInterfaceForTailscaleIPv6() {
                return Resolved(host: "[\(v6)]", kind: .tailscaleIPv6)
            }
            return Resolved(host: dns.dnsName, kind: .tailscaleDNSBackendDown(state: dns.backendState))
        }

        // MagicDNS disabled OR Tailscale CLI not installed — original
        // numeric-first ladder.
        if let v4 = scanInterfaceForTailscaleIPv4() {
            return Resolved(host: v4, kind: .tailscaleIPv4)
        }
        if let v6 = scanInterfaceForTailscaleIPv6() {
            return Resolved(host: "[\(v6)]", kind: .tailscaleIPv6)
        }
        if let dns = readTailscaleStatus() {
            if dns.backendState == "Running" {
                return Resolved(host: dns.dnsName, kind: .tailscaleDNS)
            }
            return Resolved(host: dns.dnsName, kind: .tailscaleDNSBackendDown(state: dns.backendState))
        }
        return Resolved(host: "127.0.0.1", kind: .loopback)
    }

    // MARK: - getifaddrs scans

    private static func scanInterfaceForTailscaleIPv4() -> String? {
        var ifaddrHead: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrHead) == 0, let head = ifaddrHead else { return nil }
        defer { freeifaddrs(ifaddrHead) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            // 100.64.0.0/10 = first byte 100, second byte 64..127.
            let raw = UInt32(bigEndian: addr.sin_addr.s_addr)
            let b0 = UInt8((raw >> 24) & 0xFF)
            let b1 = UInt8((raw >> 16) & 0xFF)
            guard b0 == 100, b1 >= 64, b1 <= 127 else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = withUnsafePointer(to: &addr.sin_addr) {
                inet_ntop(AF_INET, $0, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            return String(cString: buf)
        }
        return nil
    }

    private static func scanInterfaceForTailscaleIPv6() -> String? {
        var ifaddrHead: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrHead) == 0, let head = ifaddrHead else { return nil }
        defer { freeifaddrs(ifaddrHead) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            var addr = sockaddr_in6()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in6>.size)
            let bytes = withUnsafeBytes(of: addr.sin6_addr) { Array($0) }
            guard bytes.count == 16,
                  bytes[0] == 0xFD, bytes[1] == 0x7A,
                  bytes[2] == 0x11, bytes[3] == 0x5C,
                  bytes[4] == 0xA1, bytes[5] == 0xE0
            else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = withUnsafePointer(to: &addr.sin6_addr) {
                inet_ntop(AF_INET6, $0, &buf, socklen_t(INET6_ADDRSTRLEN))
            }
            return String(cString: buf)
        }
        return nil
    }

    // MARK: - Tailscale CLI status fallback

    private static let tailscaleBinaryCandidates = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Status snapshot from `tailscale status --json`. `dnsName` has the
    /// trailing dot stripped; `backendState` is the raw value (`Running`,
    /// `Stopped`, `NeedsLogin`, etc.).
    struct CLIStatus {
        let dnsName: String
        let backendState: String
    }

    private static func readTailscaleStatus() -> CLIStatus? {
        for path in tailscaleBinaryCandidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let data = try? runAndCapture(path, ["status", "--json"]),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let selfNode = json["Self"] as? [String: Any],
                  let dnsName = selfNode["DNSName"] as? String
            else { continue }
            let trimmed = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !trimmed.isEmpty else { continue }
            let state = (json["BackendState"] as? String) ?? "Unknown"
            return CLIStatus(dnsName: trimmed, backendState: state)
        }
        return nil
    }

    private static func runAndCapture(_ executable: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

}
