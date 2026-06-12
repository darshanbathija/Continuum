import Foundation

/// Parses legacy `clawdmeter://` / `clawdmeters://` pairing URLs into a
/// `PairingChallenge`. Shared so Mac URL minting and iOS scanning use the
/// same trust boundary.
public enum PairingChallengeURLParser {

    public static func parse(urlString: String) -> PairingChallenge? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "clawdmeter" || scheme == "clawdmeters",
              let host = url.host,
              let httpPort = url.port,
              isAllowedPairingHost(host),
              isValidPort(httpPort)
        else { return nil }

        let useHTTPS = (scheme == "clawdmeters")
        var token: String?
        var wsPort: Int?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items {
                switch item.name {
                case "token":
                    if let v = item.value, isValidPairingToken(v) { token = v }
                case "ws":
                    if let v = item.value, let n = Int(v), isValidPort(n) { wsPort = n }
                default: break
                }
            }
        }
        guard let token, let wsPort else { return nil }
        return PairingChallenge(
            host: host,
            port: httpPort,
            wsPort: wsPort,
            token: token,
            useHTTPS: useHTTPS
        )
    }

    public static func isAllowedPairingHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".ts.net") || host.hasSuffix(".tailnet.ts.net") { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let a = Int(parts[0]), let b = Int(parts[1]),
           let c = Int(parts[2]), let d = Int(parts[3]),
           a == 100, b >= 64, b <= 127, c >= 0, c <= 255, d >= 0, d <= 255 {
            return true
        }
        return false
    }

    public static func isValidPort(_ p: Int) -> Bool {
        p >= 1 && p <= 65535
    }

    public static func isValidPairingToken(_ s: String) -> Bool {
        guard s.count >= 16, s.count <= 256 else { return false }
        for ch in s.unicodeScalars {
            let v = ch.value
            let isAlnum = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isUrlSafe = v == 0x2D || v == 0x5F
            if !(isAlnum || isUrlSafe) { return false }
        }
        return true
    }
}
