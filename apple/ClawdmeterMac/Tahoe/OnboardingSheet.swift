import SwiftUI
import ClawdmeterShared

/// First-run welcome. Providers are opt-in and default off; this sheet uses
/// the same simple provider rows as Settings so onboarding and later changes
/// stay in sync.
struct OnboardingSheet: View {
    @Environment(\.tahoe) private var t
    var runtime: AppRuntime?
    var onDone: () -> Void
    @State private var enabledProviderIDs = ProviderEnablement.enabledProviderIDs()

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

            TahoeGlass(radius: 6, tone: .panel) {
                ProviderPreferenceRows(
                    client: runtime?.loopbackClient,
                    runtime: runtime,
                    onEnabledProvidersChanged: { enabledProviderIDs = $0 }
                )
                    .padding(16)
            }

            if enabledProviderIDs.isEmpty {
                Text("Turn on at least one provider to continue.")
                    .font(TahoeFont.body(12.5, weight: .medium))
                    .foregroundStyle(Color.orange)
            }

            HStack {
                Spacer()
                Button {
                    guard !enabledProviderIDs.isEmpty else { return }
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
                .disabled(enabledProviderIDs.isEmpty)
                .opacity(enabledProviderIDs.isEmpty ? 0.55 : 1)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(t.surfaceSolid)
        .onReceive(NotificationCenter.default.publisher(for: ProviderEnablement.changedNotification)) { _ in
            enabledProviderIDs = ProviderEnablement.enabledProviderIDs()
        }
    }
}
