import SwiftUI
import ClawdmeterShared

/// Production Code tab shell.
///
/// The Code tab uses the live session workspace: it owns session spawning,
/// transcript ingestion, composer state, permission prompts, and review panes.
struct MacCodeShell: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var presentationStore: SessionPresentationStore
    @ObservedObject var workbenchState: WorkbenchState

    var body: some View {
        SessionWorkspaceView(
            model: model,
            presentationStore: presentationStore,
            workbenchState: workbenchState
        )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.45), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 34, x: 0, y: 22)
    }
}
