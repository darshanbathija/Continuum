import SwiftUI
import AppKit
import ClawdmeterShared

/// Routes both #174's (`clawdmeterOpenWorkspaceChatTab` /
/// `clawdmeterOpenWorkspaceTerminalTab`) and #185's
/// (`newCodeChatTab` / `newCodeTerminalTab`) notification posters into the
/// same two callbacks. Extracted out of `SessionWorkspaceView.body` so the
/// SwiftUI compiler can type-check the body chain in reasonable time — four
/// extra `.onReceive` modifiers in `body` tripped the
/// "compiler is unable to type-check this expression" guard.
struct WorkspaceTabSpawnObservers: ViewModifier {
    let openChat: () -> Void
    let openTerminal: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenWorkspaceChatTab)) { _ in
                openChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newCodeChatTab)) { _ in
                openChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawdmeterOpenWorkspaceTerminalTab)) { _ in
                openTerminal()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newCodeTerminalTab)) { _ in
                openTerminal()
            }
    }
}
