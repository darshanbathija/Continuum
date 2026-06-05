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

    /// B5 cutover (2026-06-05): the relay is now the DEFAULT transport. When
    /// the key has never been written we return `true` so a fresh install
    /// routes through the relay without any opt-in. The Settings toggle writes
    /// an explicit Bool, which always wins — so a user who hits a bad relay
    /// path can flip it OFF on-device and fall back to the direct path without
    /// needing a new build. (`UserDefaults.bool` can't distinguish unset from
    /// `false`, hence the explicit `object(forKey:)` probe.)
    public static var relayDefaultEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    /// Persist the user's explicit choice (the on-device toggle). Writing this
    /// pins the value so the default-on probe above no longer applies.
    public static func setRelayDefault(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}
