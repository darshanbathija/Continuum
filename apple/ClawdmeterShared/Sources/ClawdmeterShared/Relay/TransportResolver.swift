import Foundation

/// Track B — B3: the transport-selection decision (pure; the Bonjour
/// `NWBrowser`/`NWListener` wiring that feeds it is device-gated).
///
/// Given what iOS knows about the moment, pick how to reach the Mac:
///   - **LAN-direct** — lowest latency, no cloud hop. Chosen ONLY when a
///     Bonjour host was discovered AND its TXT fingerprint matched the pairing
///     identity (`RelayLanAuth.discoveryFingerprint`). An unverified LAN host is
///     NEVER trusted — that's the whole point of D3 (an impostor advertiser must
///     not capture traffic).
///   - **relay** — the default cloud path when `relayDefault` is on and LAN
///     isn't available/verified.
///   - **tailscaleDirect** — the legacy path while `relayDefault` is off.
public enum RelayTransportChoice: String, Equatable, Sendable {
    case lanDirect
    case relay
    case tailscaleDirect
}

public enum TransportResolver {

    /// - Parameters:
    ///   - relayDefaultEnabled: the `clawdmeter.transport.relayDefault` flag.
    ///   - lanReachable: a paired Mac was discovered on this LAN (Bonjour) and
    ///     its endpoint resolved.
    ///   - lanFingerprintVerified: the discovered host's TXT fingerprint matched
    ///     our stored pairing identity (impostor gate).
    public static func resolve(
        relayDefaultEnabled: Bool,
        lanReachable: Bool,
        lanFingerprintVerified: Bool
    ) -> RelayTransportChoice {
        guard relayDefaultEnabled else { return .tailscaleDirect }
        // LAN-direct only when discovered AND identity-verified; otherwise relay.
        if lanReachable && lanFingerprintVerified { return .lanDirect }
        return .relay
    }
}
