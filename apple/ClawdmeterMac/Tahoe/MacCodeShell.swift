import SwiftUI

/// Production Code tab shell.
///
/// The Tahoe prototype (`MacCodeView`) still exists for previews and
/// fixture-driven visual reference, but the real Code tab should use the
/// live session workspace: it already owns session spawning, transcript
/// ingestion, composer state, permission prompts, and review panes.
struct MacCodeShell: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        SessionWorkspaceView(model: model)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.45), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 34, x: 0, y: 22)
    }
}
