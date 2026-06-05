import Foundation

/// Track B (B1): the single source of truth for "is the relay the DEFAULT
/// transport for iOS↔Mac traffic?".
///
/// Distinct from `clawdmeter.relay.enabled` (which governs whether the relay
/// socket runs at all / keep-warm for APNS). `relayDefault` governs whether the
/// 4 live streams (chat / terminal / events / frontier) and — later (B1.7) —
/// requests route through the relay multiplex instead of the direct
/// Tailscale/LAN path. Default OFF: every store falls through to its existing
/// direct connection, byte-identical.
///
/// Read once at startup-relevant seams and threaded as a Bool / a non-nil
/// `RelayMuxClient` handle — never scattered `UserDefaults.bool(...)` calls — so
/// the regression guard is a one-symbol audit. Toggling requires an app
/// relaunch to take effect (the mux client is constructed at coordinator
/// spin-up).
public enum RelayTransportFlag {
    public static let key = "clawdmeter.transport.relayDefault"

    public static var relayDefaultEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
