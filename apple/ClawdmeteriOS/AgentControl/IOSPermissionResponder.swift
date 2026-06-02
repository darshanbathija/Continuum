import Foundation
import ClawdmeterShared

/// iOS-side `PermissionResponder` that reaches the paired Mac over
/// Tailscale via the existing `AgentControlClient`. The client already
/// owns host / port / token state (UserDefaults-backed pairing) so the
/// adapter is a thin wrapper that builds the POST + maps HTTP failures
/// into `PermissionResponderError` for the V2 card to display.
public struct IOSPermissionResponder: PermissionResponder {
    public let client: AgentControlClient

    public init(client: AgentControlClient) {
        self.client = client
    }

    public func respond(sessionId: UUID, promptId: String, optionId: String) async throws {
        // The client method now returns the real HTTP outcome (true on 2xx),
        // so the racy lastError before/after snapshot is gone. On failure,
        // surface `lastError` (set by the failed POST) to the V2 card.
        let ok = await client.respondToPermissionPrompt(
            sessionId: sessionId,
            promptId: promptId,
            optionId: optionId
        )
        if !ok {
            let message = await MainActor.run { client.lastError } ?? "Permission response failed"
            throw PermissionResponderError(message)
        }
    }
}
