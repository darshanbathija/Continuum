import Foundation

/// Builds `clawdmeter://` pairing URLs for direct Tailscale transport.
public enum TailscalePairingURLBuilder {

    public static func buildURL(
        host: String,
        httpPort: UInt16,
        wsPort: UInt16,
        token: String,
        preferTLS: Bool = false
    ) -> String {
        let scheme = preferTLS ? "clawdmeters" : "clawdmeter"
        return "\(scheme)://\(host):\(httpPort)?token=\(token)&ws=\(wsPort)"
    }
}
