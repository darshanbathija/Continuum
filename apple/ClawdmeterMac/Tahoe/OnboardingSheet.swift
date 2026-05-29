import SwiftUI
import ClawdmeterShared

/// v0.29.32 first-run welcome. Providers are opt-in (off by default), so this
/// sheet lets the user turn on the ones they use right away — with the toggles
/// inline (reusing `ProviderEnableToggleRow`, which starts each poller live).
/// It also tells the user that folder + usage access are requested only when
/// needed. Shown once, gated on `ProviderEnablement.hasOnboarded`.
struct OnboardingSheet: View {
    @Environment(\.tahoe) private var t
    var runtime: AppRuntime?
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Continuum")
                    .font(TahoeFont.body(20, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("Turn on the AI providers you use. Continuum reads a provider's credentials only once you enable it — nothing is accessed in the background.")
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
                    ProviderEnableToggleRow(id: "gemini", label: "Antigravity / Gemini", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "cursor", label: "Cursor", runtime: runtime)
                    TahoeHair()
                    ProviderEnableToggleRow(id: "opencode", label: "OpenCode", runtime: runtime)
                }
                .padding(16)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(t.fg4)
                Text("Folder access is requested only when you add a repo in Code. Usage data is requested when you open the Usage tab — you stay in control of each prompt.")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    ProviderEnablement.hasOnboarded = true
                    onDone()
                } label: {
                    Text("Done")
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
        .frame(width: 470)
        .background(t.surfaceSolid)
    }
}
