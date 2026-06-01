import SwiftUI
import ClawdmeterShared

/// First-run provider opt-in. Providers start off by default and only read
/// credentials once the user enables them here or in Settings.
struct OnboardingSheet: View {
    @Environment(\.tahoe) private var t
    var runtime: AppRuntime?
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose providers")
                    .font(TahoeFont.body(20, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("Turn on the providers Continuum should use. You can change this later in Settings.")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TahoeGlass(radius: 16, tone: .panel) {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderEnableToggleRow(id: "claude", label: "Claude", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "codex", label: "Codex", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "gemini", label: "Antigravity", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "cursor", label: "Cursor", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "opencode", label: "OpenCode", runtime: runtime)
                }
                .padding(16)
            }

            HStack {
                Spacer()
                Button {
                    ProviderEnablement.hasOnboarded = true
                    onDone()
                } label: {
                    Text("Continue")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(t.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(t.surfaceSolid)
    }
}
