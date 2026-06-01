import SwiftUI
import ClawdmeterShared

/// First-run welcome. Providers are opt-in and default off; this sheet uses
/// the same simple provider rows as Settings so onboarding and later changes
/// stay in sync.
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
                Text("Choose the providers and default models you want to use.")
                    .font(TahoeFont.body(12.5))
                    .foregroundStyle(t.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TahoeGlass(radius: 16, tone: .panel) {
                ProviderPreferenceRows(client: runtime?.loopbackClient, runtime: runtime)
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
        .frame(width: 600)
        .background(t.surfaceSolid)
    }
}
