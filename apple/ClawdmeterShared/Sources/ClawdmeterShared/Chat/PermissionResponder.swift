import Foundation

/// Cross-platform dispatcher for the V2 chat surface's permission-prompt
/// card. The card lives in `ClawdmeterShared/Chat/Views/PermissionPromptCard.swift`
/// and binds to this protocol; each platform supplies a concrete
/// `PermissionResponder` that knows how to reach the daemon:
///
/// - **Mac** uses `AppDelegate.runtime.agentControlServer.boundPort` +
///   `PairingTokenStore.shared.currentToken()` (in-process loopback —
///   no Tailscale hop).
/// - **iOS** uses `AgentControlClient` (UserDefaults-backed pairing —
///   Tailscale + bearer-token round-trip).
///
/// The Codex outside-voice review (P1 #9) flagged the original
/// PermissionPromptCard as "not a clean lift" because it imported
/// Mac-only types directly. This protocol-based factoring lets the
/// card move to Shared without bleeding daemon-implementation details.
public protocol PermissionResponder: Sendable {
    /// POST `/sessions/:id/permission-respond` with the user's choice.
    /// Throws on transport / HTTP failure; the card catches and renders
    /// the error inline. The wire shape is the existing
    /// `PermissionRespondRequest { promptId, optionId }` envelope —
    /// implementers just need the daemon address + bearer token.
    func respond(sessionId: UUID, promptId: String, optionId: String) async throws
}

/// Boxed-error wrapper so concrete responders can surface a string
/// reason without each implementer rolling their own Error type.
/// The card displays `error.localizedDescription` directly.
public struct PermissionResponderError: Error, LocalizedError, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}
