import SwiftUI
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

/// iOS PR pane — shows the open PR (if any), with Create / Merge / Open
/// in GitHub actions. Wires through `GET /sessions/:id/pr` +
/// `POST /sessions/:id/{create-pr,merge}`.
///
/// Sessions v2 Phase 4.
struct iOSPRPane: View {
    @Environment(\.tahoe) private var t
    let session: AgentSession
    @ObservedObject var client: AgentControlClient
    var outbox: MobileCommandOutbox?

    @State private var pr: PRStatus?
    @State private var isLoading: Bool = true
    @State private var isCreating: Bool = false
    @State private var showingMergeConfirm: Bool = false
    @State private var bannerMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading PR…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pr {
                prCard(pr)
            } else {
                emptyState
            }
        }
        .navigationTitle("Pull Request")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .overlay(alignment: .top) {
            if let bannerMessage {
                Text(bannerMessage)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(SessionsV2Theme.accent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            TahoeIcon("pull", size: 30)
                .foregroundStyle(t.fg4)
            Text("No PR yet")
                .font(TahoeFont.body(15, weight: .bold))
                .foregroundStyle(t.fg2)
            Button {
                Task { await createPR() }
            } label: {
                HStack(spacing: 8) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        TahoeIcon("pull", size: 12, weight: .bold)
                    }
                    Text(isCreating ? "Creating..." : "Create PR")
                        .font(TahoeFont.body(13, weight: .bold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
            .accessibilityLabel("Create pull request")
            .accessibilityHint("Runs gh pr create on the Mac and opens the PR.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func prCard(_ pr: PRStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    statePill(pr.state)
                    Spacer()
                    Text("#\(pr.number)")
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(t.fg3)
                }
                Text(pr.title)
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)

                TahoeGlass(radius: 14, tone: .chip, solid: t.dark ? true : nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        prMetric("+\(pr.additions)", icon: "plus", color: .green)
                        prMetric("-\(pr.deletions)", icon: "minus", color: .red)
                        prMetric("\(pr.changedFiles) files", icon: "doc", color: t.fg3)
                        if let review = pr.reviewDecision, !review.isEmpty {
                            prMetric("Review: \(review)", icon: "check", color: t.accent)
                        }
                        if let checks = pr.checksRollup, !checks.isEmpty {
                            prMetric("CI: \(checks)", icon: checksGlyph(checks), color: checksColor(checks))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(pr.body)
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let url = URL(string: pr.url) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 7) {
                        TahoeIcon("link", size: 12)
                        Text("Open PR on GitHub")
                            .font(TahoeFont.body(12.5, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(t.glassTintHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(t.hairline, lineWidth: 0.5)
                    }
                    .foregroundStyle(t.fg)
                }
                .buttonStyle(.plain)

                let mergeAllowed = canMerge(pr)
                VStack(alignment: .leading, spacing: 6) {
                    Button(role: .destructive) {
                        if mergeAllowed {
                            showingMergeConfirm = true
                        }
                    } label: {
                        HStack(spacing: 7) {
                            TahoeIcon("branch", size: 12)
                            Text("Merge")
                                .font(TahoeFont.body(12.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: mergeAllowed ? [t.accent, t.accentDeepC] : [t.hair2, t.hair2],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(mergeAllowed ? .white : t.fg3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!mergeAllowed)
                    .opacity(mergeAllowed ? 1 : 0.45)
                    .accessibilityLabel("Merge pull request to main")
                    .accessibilityHint(mergeAllowed ? "Asks for confirmation before merging." : mergeBlockedReason(pr))
                    if !mergeAllowed {
                        Text(mergeBlockedReason(pr))
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .alert("Merge to main?", isPresented: $showingMergeConfirm) {
                    Button("Merge anyway", role: .destructive) { Task { await merge() } }
                    Button("Open PR instead") { showingMergeConfirm = false }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will commit to your local main branch.")
                }
            }
            .padding(16)
        }
    }

    private func prMetric(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            TahoeIcon(icon, size: 11)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(color)
            Spacer()
        }
    }

    private func statePill(_ state: PRStatus.State) -> some View {
        Text(state.rawValue.capitalized)
            .font(TahoeFont.body(11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(stateColor(state).opacity(0.18), in: Capsule())
            .foregroundStyle(stateColor(state))
    }

    private func stateColor(_ state: PRStatus.State) -> Color {
        switch state {
        case .open:   return .green
        case .merged: return .purple
        case .closed: return .red
        case .draft:  return .secondary
        }
    }

    private func checksGlyph(_ rollup: String) -> String {
        switch rollup.lowercased() {
        case "success", "passed":        return "checkmark.circle"
        case "failure", "failed", "error": return "xmark.circle"
        case "pending", "running", "in_progress", "queued":
            return "clock.arrow.circlepath"
        case "neutral", "skipped":       return "minus.circle"
        default:                          return "questionmark.circle"
        }
    }

    private func checksColor(_ rollup: String) -> Color {
        switch rollup.lowercased() {
        case "success", "passed":        return .green
        case "failure", "failed", "error": return .red
        case "pending", "running", "in_progress", "queued":
            return SessionsV2Theme.warn
        default:                          return .secondary
        }
    }

    private func canMerge(_ pr: PRStatus) -> Bool {
        guard pr.state == .open else { return false }
        guard let checks = pr.checksRollup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checks.isEmpty
        else { return true }
        let normalized = checks.lowercased()
        return normalized == "success" || normalized == "passed"
    }

    private func mergeBlockedReason(_ pr: PRStatus) -> String {
        if pr.state != .open {
            return "Merge unavailable: PR is \(pr.state.rawValue)."
        }
        guard let checks = pr.checksRollup, !checks.isEmpty else {
            return "Merge unavailable."
        }
        switch checks.lowercased() {
        case "pending", "running", "in_progress", "queued":
            return "Merge waits for CI to finish."
        case "failure", "failed", "error":
            return "Merge blocked by failing CI."
        default:
            return "Merge blocked by CI state: \(checks)."
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        self.pr = await client.getPRStatus(sessionId: session.id)
        isLoading = false
    }

    @MainActor
    private func createPR() async {
        isCreating = true
        bannerMessage = "Creating PR…"
        defer { isCreating = false }
        if let outbox {
            outbox.enqueueCreatePR(sessionId: session.id)
            bannerMessage = "Queued PR creation"
        } else {
            let result = await client.createPR(sessionId: session.id)
            bannerMessage = result == nil ? "Failed - see logs" : "PR created"
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        bannerMessage = nil
        await refresh()
    }

    @MainActor
    private func merge() async {
        bannerMessage = "Merging…"
        if let outbox {
            outbox.enqueueMerge(sessionId: session.id)
            bannerMessage = "Queued merge"
        } else {
            let ok = await client.merge(sessionId: session.id)?.ok == true
            bannerMessage = ok ? "Merged" : "Merge failed - open PR or resolve on Mac"
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        bannerMessage = nil
    }
}
