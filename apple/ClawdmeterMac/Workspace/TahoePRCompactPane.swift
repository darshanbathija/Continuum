import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoePRCompactPane: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var coordinator: PRCoordinator
    let chatStore: SessionChatStore?
    let onBeforeMerge: (() async -> Bool)?
    @State private var localActionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let state = coordinator.snapshot {
                    Text(state.title)
                        .font(TahoeFont.body(13, weight: .bold))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(state.url.host() ?? "github.com") · #\(state.number) · \(state.state.lowercased())")
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(t.fg3)
                        .contextMenu {
                            Button("Copy PR URL") { copy(state.url.absoluteString) }
                            Button("Copy PR Number") { copy("#\(state.number)") }
                        }

                    TahoeGlass(radius: 12, tone: .chip) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Checks")
                                .font(TahoeFont.body(11, weight: .semibold))
                                .foregroundStyle(t.fg3)
                                .padding(.bottom, 6)
                            prStatusRow("review", state.reviewState ?? "pending", state.reviewState == "APPROVED")
                            prStatusRow("ci", state.checksRollup ?? "unknown", state.checksRollup == "success")
                            prStatusRow("changes", "+\(state.additions) -\(state.deletions)", true)
                            prStatusRow("todos", todoGateLabel, todoGatePassed)
                            if !state.checks.isEmpty {
                                TahoeHair().padding(.vertical, 6)
                                ForEach(state.checks) { check in
                                    prCheckRow(check)
                                }
                            }
                        }
                        .padding(12)
                    }

                    Menu {
                        Button("Open on GitHub") { NSWorkspace.shared.open(state.url) }
                        Button("Open checks") { openChecks(state) }
                        Button("Open deployments") { openDeployments(state) }
                        Button("Copy URL") { copy(state.url.absoluteString) }
                        Button("Copy Number") { copy("#\(state.number)") }
                        Button("Rerun failed checks") { Task { await rerunFailedChecks(state) } }
                            .disabled(PRCoordinator.repoSlug(from: state.url) == nil || failedCheckRunIDs(state).isEmpty)
                        Button("Ask agent to fix checks") { enqueueFixChecksPrompt(state) }
                    } label: {
                        HStack(spacing: 6) {
                            TahoeIcon("pull", size: 12)
                            Text("PR Actions")
                                .font(TahoeFont.body(12, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(.white)

                    if state.state == "OPEN", coordinator.canUseDaemonActions {
                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.approve() } }) {
                                Text("Approve")
                            }
                            TahoeGhostButton(size: .m, action: { enqueueReviewRequestPrompt(state) }) {
                                Text("Request changes")
                            }
                            TahoeGhostButton(size: .m, action: { Task { await merge(state) } }) {
                                Text(canMerge(state) ? "Merge" : "Merge blocked")
                            }
                            .disabled(!canMerge(state))
                            .help(todoGatePassed ? "Merge this PR" : "Open TODOs must be completed before merge")
                        }
                    }
                } else {
                    TahoeEmptyReviewState(icon: "pull", title: "No PR detected", body: "Paste a PR URL or let the agent create one.")
                    TextField("https://github.com/owner/repo/pull/123", text: $coordinator.manualURL)
                        .textFieldStyle(.roundedBorder)
                        .font(TahoeFont.mono(11.5))
                        .accessibilityLabel("Pull request URL")
                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: { coordinator.loadFromManualURL() }) {
                            Text("Load")
                        }
                        if coordinator.canUseDaemonActions {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.createPR() } }) {
                                TahoeIcon("pull", size: 11)
                                Text("Create PR")
                            }
                            TahoeGhostButton(size: .m, action: { enqueueDraftPRPrompt() }) {
                                TahoeIcon("doc", size: 11)
                                Text("Draft PR")
                            }
                        }
                    }
                }
                if coordinator.isRefreshing || coordinator.isMutating {
                    ProgressView().controlSize(.small)
                }
                if let err = coordinator.lastError ?? localActionError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { coordinator.startWatching() }
        .onDisappear { coordinator.stopWatching() }
    }

    private func prStatusRow(_ name: String, _ status: String, _ passed: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(passed ? SessionsV2Theme.success : SessionsV2Theme.warn)
                .frame(width: 14, height: 14)
                .overlay {
                    if passed {
                        TahoeIcon("check", size: 8, weight: .bold).foregroundStyle(.white)
                    }
                }
            Text(name)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg)
            Spacer()
            Text(status)
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 6)
    }

    private func prCheckRow(_ check: PRCheckMirror) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(check.state == .success ? Color.green : (check.state == .failure ? Color.red : Color.yellow))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if let url = check.url {
                    Text(url)
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(check.state.rawValue)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let raw = check.url, let url = URL(string: raw) {
                Button("Open check") { NSWorkspace.shared.open(url) }
            }
            Button("Copy check name") { copy(check.name) }
            if let runID = runID(from: check.url) {
                Button("Rerun this check") { Task { await rerunCheck(runID: runID, state: coordinator.snapshot) } }
            }
        }
    }

    private var todoGateLabel: String {
        let todos = chatStore?.snapshot.codexTodos ?? []
        guard !todos.isEmpty else { return "none" }
        let open = todos.filter { $0.status != "completed" }.count
        return open == 0 ? "clear" : "\(open) open"
    }

    private var todoGatePassed: Bool {
        (chatStore?.snapshot.codexTodos ?? []).allSatisfy { $0.status == "completed" }
    }

    private func canMerge(_ state: PRCoordinator.Snapshot) -> Bool {
        PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: coordinator.canUseDaemonActions)
            && todoGatePassed
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openChecks(_ state: PRCoordinator.Snapshot) {
        guard let identity = PRCoordinator.approvalIdentity(for: state),
              let url = URL(string: "https://github.com/\(identity.repo)/pull/\(identity.number)/checks")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openDeployments(_ state: PRCoordinator.Snapshot) {
        guard let identity = PRCoordinator.approvalIdentity(for: state),
              let url = URL(string: "https://github.com/\(identity.repo)/deployments")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func enqueueFixChecksPrompt(_ state: PRCoordinator.Snapshot) {
        ComposerInsertionInbox.shared.enqueue(text: "Inspect PR #\(state.number), read the failing checks, fix the errors, and rerun the focused tests.\n", autoSend: false)
    }

    private func enqueueReviewRequestPrompt(_ state: PRCoordinator.Snapshot) {
        ComposerInsertionInbox.shared.enqueue(text: "Review PR #\(state.number) and leave a concise request-changes summary covering the unresolved issues.\n", autoSend: false)
    }

    private func enqueueDraftPRPrompt() {
        ComposerInsertionInbox.shared.enqueue(text: "Create a draft PR with a concise title, a tested-change summary, verification steps, and known risks.\n", autoSend: false)
    }

    @MainActor
    private func rerunFailedChecks(_ state: PRCoordinator.Snapshot) async {
        for runID in failedCheckRunIDs(state) {
            await rerunCheck(runID: runID, state: state)
        }
        coordinator.refreshNow()
    }

    @MainActor
    private func rerunCheck(runID: String, state: PRCoordinator.Snapshot?) async {
        guard let state, let identity = PRCoordinator.approvalIdentity(for: state) else { return }
        // Root cause: `process.waitUntilExit()` does NOT suspend the actor, so
        // running the `gh run rerun` subprocess inline froze the UI for the full
        // network round-trip. Mirror `load()` and run it off the main actor.
        let repo = identity.repo
        localActionError = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "run", "rerun", runID, "--repo", repo]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return nil
                }
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return stderr.isEmpty ? "Failed to rerun check \(runID)." : String(stderr.prefix(220))
            } catch {
                return "Failed to run gh: \(error.localizedDescription)"
            }
        }.value
    }

    private func failedCheckRunIDs(_ state: PRCoordinator.Snapshot) -> [String] {
        state.checks
            .filter { $0.state == .failure }
            .compactMap { runID(from: $0.url) }
    }

    private func runID(from rawURL: String?) -> String? {
        guard let rawURL, let range = rawURL.range(of: #"/actions/runs/([0-9]+)"#, options: .regularExpression) else { return nil }
        let match = String(rawURL[range])
        return match.split(separator: "/").last.map(String.init)
    }

    private func merge(_ state: PRCoordinator.Snapshot) async {
        guard canMerge(state) else {
            localActionError = todoGatePassed ? "Merge is blocked by checks." : "Merge is blocked until open TODOs are completed."
            return
        }
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
