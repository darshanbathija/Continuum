import SwiftUI
import ClawdmeterShared

/// T11: banner shown when "Open project on Mac" returns 423 Locked. The
/// "Wake Mac" button calls the daemon's `/workspaces/wake-mac` endpoint
/// (which shells `caffeinate -u -t 5`), then the user re-taps Open
/// Project on a hopefully-awake Mac.
struct IOSWakeMacBanner: View {
    @ObservedObject var client: AgentControlClient
    var onDismiss: () -> Void

    @State private var isWaking: Bool = false
    @State private var lastResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.orange)
                Text("Mac is asleep or locked").font(.callout.weight(.semibold))
            }
            Text("Wake it, then tap Open Project again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(isWaking ? "Waking…" : "Wake Mac", action: ContinuumAnalytics.wrapButton("wake_mac", { Task { await wake() } }))
                .buttonStyle(.borderedProminent)
                .disabled(isWaking)
                Button("Dismiss", action: ContinuumAnalytics.wrapButton("dismiss", onDismiss))
                    .buttonStyle(.bordered)
            }
            if let lastResult {
                Text(lastResult).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.5)))
    }

    private func wake() async {
        isWaking = true
        defer { isWaking = false }
        let ok = await client.wakeMacForOpenLocal(idempotencyKey: UUID().uuidString)
        lastResult = ok
            ? "Wake signal sent. If the lock screen is up, unlock it on the Mac before tapping Open Project again."
            : "Couldn't reach the wake daemon. Open the Mac manually."
    }
}
