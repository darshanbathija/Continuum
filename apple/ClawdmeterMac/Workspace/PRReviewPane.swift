import SwiftUI
import AppKit
import ClawdmeterShared

/// G16 PR review surface. Shows the PR tied to this session (auto-detected
/// from chat, or manually pasted). Renders state badge + title + author +
/// body + an Approve button that shells out to `gh pr review --approve`.
struct PRReviewPane: View {
    let session: AgentSession
    @ObservedObject var coordinator: PRCoordinator
    let onBeforeMerge: (() async -> Bool)?
    @State private var localActionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let state = coordinator.snapshot {
                    prContent(state)
                        .padding(14)
                } else {
                    emptyState
                }
            }
        }
        // T10 opt-in poll lifecycle: only run the 30s `gh pr view` loop
        // while the user is looking at the PR tab. Snapshot subscription
        // (PRMirror.attach) keeps URL detection alive in the background.
        .onAppear { coordinator.startWatching() }
        .onDisappear { coordinator.stopWatching() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("PR")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if coordinator.isRefreshing || coordinator.isMutating {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let state = coordinator.snapshot {
                Button(action: ContinuumAnalytics.wrapButton(
                        "prreviewpane_l44",
                        {
                    NSWorkspace.shared.open(state.url)
                
                        }
                    )) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Open in browser")
            }
            Button(action: ContinuumAnalytics.wrapButton(
                    "prreviewpane_l53",
                    {
 coordinator.refreshNow() 
                    }
                )) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(PressableButtonStyle())
            .help("Refresh PR state")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func prContent(_ state: PRCoordinator.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                stateBadge(state.state)
                Text("#\(state.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let review = state.reviewState {
                    reviewBadge(review)
                }
                if let checks = state.checksRollup {
                    checksBadge(checks)
                }
            }
            Text(state.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                Text(state.author ?? state.source.rawValue)
                    .font(.system(size: 11))
                Text("+\(state.additions)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green)
                Text("-\(state.deletions)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }
            .foregroundStyle(.secondary)
            if !state.body.isEmpty {
                Text(state.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.state == "OPEN" {
                HStack(spacing: 8) {
                            Button(action: ContinuumAnalytics.wrapButton(
                                    "prreviewpane_l108",
                                    {
 Task { await coordinator.approve() } 
                                    }
                                )) {
                                Label("Approve PR", systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button(action: ContinuumAnalytics.wrapButton(
                            "prreviewpane_l114",
                            {
 NSWorkspace.shared.open(state.url) 
                            }
                        )) {
                        Label("Open on GitHub", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    if coordinator.canUseDaemonActions {
                        if PRCoordinator.canMerge(
                            snapshot: state,
                            canUseDaemonActions: coordinator.canUseDaemonActions
                        ) {
                            Button(action: ContinuumAnalytics.wrapButton(
                                    "prreviewpane_l124",
                                    {
                                Task {
                                    if let onBeforeMerge {
                                        guard await onBeforeMerge() else {
                                            localActionError = "Safety checkpoint failed. Merge cancelled."
                                            return
                                        }
                                    }
                                    localActionError = nil
                                    await coordinator.merge()
                                }
                            
                                    }
                                )) {
                                Label("Merge", systemImage: "arrow.triangle.merge")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: ContinuumAnalytics.wrapButton(
                                    "prreviewpane_l141",
                                    {
                                    }
                                )) {
                                Label("Merge blocked", systemImage: "shield.slash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .disabled(true)
                            .help(state.checksRollup == nil
                                ? "No CI checks were reported."
                                : "Checks must pass before merging.")
                        }
                    }
                }
            }
            if let err = coordinator.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if let localActionError {
                Text(localActionError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Text("Last checked \(state.lastChecked, style: .relative) ago")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No PR detected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Paste a PR URL or have the agent run `gh pr create`.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            HStack(spacing: 6) {
                TextField("https://github.com/owner/repo/pull/123",
                          text: $coordinator.manualURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("Load", action: ContinuumAnalytics.wrapButton(
                        "load",
                        {
 coordinator.loadFromManualURL() 
                        }
                    ))
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 18)
            if coordinator.canUseDaemonActions {
                Button(action: ContinuumAnalytics.wrapButton(
                        "prreviewpane_l195",
                        {
 Task { await coordinator.createPR() } 
                        }
                    )) {
                    Label("Create PR", systemImage: "arrow.triangle.pull")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let err = coordinator.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func stateBadge(_ state: String) -> some View {
        let (tint, label): (Color, String) = {
            switch state {
            case "MERGED": return (.purple, "Merged")
            case "CLOSED": return (.red, "Closed")
            case "OPEN": return (.green, "Open")
            default: return (.secondary, state.capitalized)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func reviewBadge(_ review: String) -> some View {
        let (tint, label): (Color, String) = {
            switch review {
            case "APPROVED": return (.green, "Approved")
            case "CHANGES_REQUESTED": return (.orange, "Changes requested")
            case "COMMENTED": return (.blue, "Commented")
            default: return (.secondary, review.capitalized)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func checksBadge(_ checks: String) -> some View {
        let (tint, label): (Color, String) = {
            switch checks {
            case "success": return (.green, "Checks passed")
            case "failure": return (.red, "Checks failing")
            case "pending": return (.orange, "Checks pending")
            default: return (.secondary, checks.capitalized)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
