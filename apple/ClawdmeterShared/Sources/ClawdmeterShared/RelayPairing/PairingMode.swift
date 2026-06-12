import Foundation

/// How the Mac and iPhone establish a connection during pairing.
public enum PairingMode: String, CaseIterable, Sendable, Identifiable {
    case cloud
    case tailscale

    public static let storageKey = "clawdmeter.pairing.mode"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "Continuum Cloud"
        case .tailscale: return "Tailscale"
        }
    }

    public var subtitle: String {
        switch self {
        case .cloud:
            return "Pair over the encrypted relay — no VPN or public IP required."
        case .tailscale:
            return "Pair directly over your Tailnet — both devices need Tailscale."
        }
    }

    public var systemImage: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .tailscale: return "network"
        }
    }

    /// Whether iOS should route through the relay transport after pairing.
    public var prefersRelayTransport: Bool {
        switch self {
        case .cloud: return true
        case .tailscale: return false
        }
    }
}
