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
        // The existing client method is fire-and-forget (void). We snapshot
        // `lastError` before + after; if a new error string appears, surface
        // it. Not perfect — concurrent calls could race the error — but
        // matches the existing contract used elsewhere in the V2 surface.
        let before = await MainActor.run { client.lastError }
        await client.respondToPermissionPrompt(
            sessionId: sessionId,
            promptId: promptId,
            optionId: optionId
        )
        let after = await MainActor.run { client.lastError }
        if let after, after != before {
            throw PermissionResponderError(after)
        }
    }
}
