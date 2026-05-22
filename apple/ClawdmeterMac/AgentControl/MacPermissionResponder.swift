import Foundation
import ClawdmeterShared

/// Mac-side `PermissionResponder` that reaches the local daemon over
/// loopback. Pre-V2 this code lived inline in `PermissionPromptCard`
/// on `ChatSoloView.swift:228` with a hard dependency on
/// `AppDelegate.runtime`. Codex outside-voice review P1 #9 flagged
/// that as "not a clean lift to Shared"; this adapter encapsulates
/// the Mac-only dependencies behind the protocol so the card itself
/// stays platform-agnostic.
public struct MacPermissionResponder: PermissionResponder {
    public init() {}

    public func respond(sessionId: UUID, promptId: String, optionId: String) async throws {
        let portOpt: Int? = await MainActor.run {
            AppDelegate.runtime?.agentControlServer.boundPort.map(Int.init)
        }
        guard let port = portOpt else {
            throw PermissionResponderError("Daemon not running.")
        }
        let token = await MainActor.run { PairingTokenStore.shared.currentToken() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/sessions/\(sessionId.uuidString)/permission-respond") else {
            throw PermissionResponderError("Bad daemon URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PermissionRespondRequest(promptId: promptId, optionId: optionId))
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PermissionResponderError("Daemon HTTP \(http.statusCode)")
        }
    }
}
