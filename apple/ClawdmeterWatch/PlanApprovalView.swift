import SwiftUI
import ClawdmeterShared

/// Watch approval sheet. Reads the latest plan + goal from App Group
/// UserDefaults (the Watch app's WatchPlanBridge fills these via
/// WCSession from the iPhone). Tapping Approve sends a WCSession message
/// back; the iPhone forwards a `POST /sessions/:id/approve-plan` to the
/// Mac daemon over Tailscale.
struct PlanApprovalView: View {
    @ObservedObject var bridge: WatchPlanBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let goal = bridge.latestGoal {
                Text(goal)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            } else {
                Text("Plan ready")
                    .font(.system(size: 14, weight: .semibold))
            }
            if let summary = bridge.latestPlanSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 4)
            Button {
                bridge.approve()
            } label: {
                Text("Approve & run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // Tahoe 26 redesign: Halo cyan accent (was terra-cotta).
            .tint(TahoeAccent.halo.base.color)
        }
        .padding(8)
    }
}
