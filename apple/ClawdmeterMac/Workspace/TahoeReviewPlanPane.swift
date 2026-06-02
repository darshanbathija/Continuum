import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeReviewPlanPane: View {
    @Environment(\.tahoe) private var t
    let pendingPlanText: String?
    let approvedPlanText: String?
    let chatStore: SessionChatStore?

    private var explicitPlanText: String? {
        for candidate in [pendingPlanText, approvedPlanText] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { continue }
            return trimmed
        }
        return nil
    }

    private var steps: [String] {
        if let planText = explicitPlanText {
            return TahoePlanParser.steps(from: planText, cap: 8)
        }
        return chatStore?.snapshot.codexTodos.prefix(8).map(\.text) ?? []
    }

    private var emptyCopy: String {
        "No approved plan file has been captured for this session."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plan · \(steps.count) steps")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 10)
                if steps.isEmpty {
                    TahoeEmptyReviewState(icon: "doc", title: "No approved plan", body: emptyCopy)
                } else {
                    TahoeReviewPlanRows(steps: steps)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
