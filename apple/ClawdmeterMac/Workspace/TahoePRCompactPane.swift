import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoePRCompactPane: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var coordinator: PRCoordinator
    let chatStore: SessionChatStore?
    let onBeforeMerge: (() async -> Bool)?
    @State private var localActionError: String?

    struct ActionDescriptor: Equatable {
        let title: String
        let accessibilityIdentifier: String
        let isEnabled: Bool

        init(title: String, accessibilityIdentifier: String, isEnabled: Bool = true) {
            self.title = title
            self.accessibilityIdentifier = accessibilityIdentifier
            self.isEnabled = isEnabled
        }
    }

    struct EmptyActionDescriptors: Equatable {
        static let rootAccessibilityIdentifier = "code.pr.empty"
        static let manualURLAccessibilityIdentifier = "code.pr.manual-url"

        let load: ActionDescriptor
        let create: ActionDescriptor?
        let draft: ActionDescriptor?
    }

    struct StatusRowDescriptor: Equatable {
        let key: String
        let title: String
        let status: String
        let passed: Bool
        var accessibilityIdentifier: String { "code.pr.status.\(key)" }
    }

    struct CheckRowDescriptor: Equatable {
        static let rowAccessibilityIdentifier = "code.pr.check.row"

        let name: String
        let state: String
        let url: String?
        let open: ActionDescriptor?
        let copyName: ActionDescriptor
        let rerun: ActionDescriptor?
    }

    struct ActionMenuDescriptors: Equatable {
        static let menuAccessibilityIdentifier = "code.pr.actions"

        let openGitHub: ActionDescriptor
        let openChecks: ActionDescriptor
        let openDeployments: ActionDescriptor
        let copyURL: ActionDescriptor
        let copyNumber: ActionDescriptor
        let rerunFailedChecks: ActionDescriptor
        let askAgentToFixChecks: ActionDescriptor
    }

    struct ReviewActionDescriptors: Equatable {
        let approve: ActionDescriptor
        let requestChanges: ActionDescriptor
        let merge: ActionDescriptor
    }

    static func emptyActionDescriptors(canUseDaemonActions: Bool) -> EmptyActionDescriptors {
        EmptyActionDescriptors(
            load: ActionDescriptor(title: "Load", accessibilityIdentifier: "code.pr.load"),
            create: canUseDaemonActions
                ? ActionDescriptor(title: "Create PR", accessibilityIdentifier: "code.pr.create")
                : nil,
            draft: canUseDaemonActions
                ? ActionDescriptor(title: "Draft PR", accessibilityIdentifier: "code.pr.draft")
                : nil
        )
    }

    static func statusRowDescriptor(
        key: String,
        title: String,
        status: String,
        passed: Bool
    ) -> StatusRowDescriptor {
        StatusRowDescriptor(key: key, title: title, status: status, passed: passed)
    }

    static func checkRowDescriptor(_ check: PRCheckMirror) -> CheckRowDescriptor {
        let runID = runID(from: check.url)
        return CheckRowDescriptor(
            name: check.name,
            state: check.state.rawValue,
            url: check.url,
            open: check.url.flatMap { URL(string: $0) }.map { _ in
                ActionDescriptor(title: "Open check", accessibilityIdentifier: "code.pr.check.open")
            },
            copyName: ActionDescriptor(title: "Copy check name", accessibilityIdentifier: "code.pr.check.copy-name"),
            rerun: runID.map { _ in
                ActionDescriptor(title: "Rerun this check", accessibilityIdentifier: "code.pr.check.rerun")
            }
        )
    }

    static func actionMenuDescriptors(for state: PRCoordinator.Snapshot) -> ActionMenuDescriptors {
        ActionMenuDescriptors(
            openGitHub: ActionDescriptor(title: "Open on GitHub", accessibilityIdentifier: "code.pr.open-github"),
            openChecks: ActionDescriptor(title: "Open checks", accessibilityIdentifier: "code.pr.open-checks"),
            openDeployments: ActionDescriptor(title: "Open deployments", accessibilityIdentifier: "code.pr.open-deployments"),
            copyURL: ActionDescriptor(title: "Copy URL", accessibilityIdentifier: "code.pr.copy-url"),
            copyNumber: ActionDescriptor(title: "Copy Number", accessibilityIdentifier: "code.pr.copy-number"),
            rerunFailedChecks: ActionDescriptor(
                title: "Rerun failed checks",
                accessibilityIdentifier: "code.pr.rerun-failed-checks",
                isEnabled: PRCoordinator.repoSlug(from: state.url) != nil && !failedCheckRunIDs(in: state).isEmpty
            ),
            askAgentToFixChecks: ActionDescriptor(
                title: "Ask agent to fix checks",
                accessibilityIdentifier: "code.pr.ask-agent-fix-checks"
            )
        )
    }

    static func reviewActionDescriptors(
        for state: PRCoordinator.Snapshot,
        canUseDaemonActions: Bool,
        todoGatePassed: Bool
    ) -> ReviewActionDescriptors? {
        guard state.state == "OPEN", canUseDaemonActions else { return nil }
        let mergeEnabled = PRCoordinator.canMerge(snapshot: state, canUseDaemonActions: canUseDaemonActions) && todoGatePassed
        return ReviewActionDescriptors(
            approve: ActionDescriptor(title: "Approve", accessibilityIdentifier: "code.pr.approve"),
            requestChanges: ActionDescriptor(title: "Request changes", accessibilityIdentifier: "code.pr.request-changes"),
            merge: ActionDescriptor(
                title: mergeEnabled ? "Merge" : "Merge blocked",
                accessibilityIdentifier: "code.pr.merge",
                isEnabled: mergeEnabled
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let state = coordinator.snapshot {
                    let actionMenu = Self.actionMenuDescriptors(for: state)
                    let reviewActions = Self.reviewActionDescriptors(
                        for: state,
                        canUseDaemonActions: coordinator.canUseDaemonActions,
                        todoGatePassed: todoGatePassed
                    )
                    Text(state.title)
                        .font(TahoeFont.body(13, weight: .bold))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("code.pr.title")
                    Text("\(state.url.host() ?? "github.com") · #\(state.number) · \(state.state.lowercased())")
                        .font(TahoeFont.mono(11.5))
                        .foregroundStyle(t.fg3)
                        .accessibilityIdentifier("code.pr.subtitle")
                        .contextMenu {
                            Button("Copy PR URL") { copy(state.url.absoluteString) }
                                .accessibilityIdentifier(actionMenu.copyURL.accessibilityIdentifier)
                            Button("Copy PR Number") { copy("#\(state.number)") }
                                .accessibilityIdentifier(actionMenu.copyNumber.accessibilityIdentifier)
                        }

                    TahoeGlass(radius: 6, tone: .chip) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Checks")
                                .font(TahoeFont.body(11, weight: .semibold))
                                .foregroundStyle(t.fg3)
                                .padding(.bottom, 6)
                            prStatusRow(Self.statusRowDescriptor(
                                key: "review",
                                title: "review",
                                status: state.reviewState ?? "pending",
                                passed: state.reviewState == "APPROVED"
                            ))
                            prStatusRow(Self.statusRowDescriptor(
                                key: "ci",
                                title: "ci",
                                status: state.checksRollup ?? "unknown",
                                passed: state.checksRollup == "success"
                            ))
                            prStatusRow(Self.statusRowDescriptor(
                                key: "changes",
                                title: "changes",
                                status: "+\(state.additions) -\(state.deletions)",
                                passed: true
                            ))
                            prStatusRow(Self.statusRowDescriptor(
                                key: "todos",
                                title: "todos",
                                status: todoGateLabel,
                                passed: todoGatePassed
                            ))
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
                        Button(actionMenu.openGitHub.title) { NSWorkspace.shared.open(state.url) }
                            .accessibilityIdentifier(actionMenu.openGitHub.accessibilityIdentifier)
                        Button(actionMenu.openChecks.title) { openChecks(state) }
                            .accessibilityIdentifier(actionMenu.openChecks.accessibilityIdentifier)
                        Button(actionMenu.openDeployments.title) { openDeployments(state) }
                            .accessibilityIdentifier(actionMenu.openDeployments.accessibilityIdentifier)
                        Button(actionMenu.copyURL.title) { copy(state.url.absoluteString) }
                            .accessibilityIdentifier(actionMenu.copyURL.accessibilityIdentifier)
                        Button(actionMenu.copyNumber.title) { copy("#\(state.number)") }
                            .accessibilityIdentifier(actionMenu.copyNumber.accessibilityIdentifier)
                        Button(actionMenu.rerunFailedChecks.title) { Task { await rerunFailedChecks(state) } }
                            .disabled(!actionMenu.rerunFailedChecks.isEnabled)
                            .accessibilityIdentifier(actionMenu.rerunFailedChecks.accessibilityIdentifier)
                        Button(actionMenu.askAgentToFixChecks.title) { enqueueFixChecksPrompt(state) }
                            .accessibilityIdentifier(actionMenu.askAgentToFixChecks.accessibilityIdentifier)
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
                    .accessibilityIdentifier(ActionMenuDescriptors.menuAccessibilityIdentifier)

                    if let reviewActions {
                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.approve() } }) {
                                Text(reviewActions.approve.title)
                            }
                            .accessibilityIdentifier(reviewActions.approve.accessibilityIdentifier)
                            TahoeGhostButton(size: .m, action: { enqueueReviewRequestPrompt(state) }) {
                                Text(reviewActions.requestChanges.title)
                            }
                            .accessibilityIdentifier(reviewActions.requestChanges.accessibilityIdentifier)
                            TahoeGhostButton(size: .m, action: { Task { await merge(state) } }) {
                                Text(reviewActions.merge.title)
                            }
                            .disabled(!reviewActions.merge.isEnabled)
                            .help(todoGatePassed ? "Merge this PR" : "Open TODOs must be completed before merge")
                            .accessibilityIdentifier(reviewActions.merge.accessibilityIdentifier)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("code.pr.review-actions")
                    }
                } else {
                    let emptyActions = Self.emptyActionDescriptors(canUseDaemonActions: coordinator.canUseDaemonActions)
                    TahoeEmptyReviewState(icon: "pull", title: "No PR detected", body: "Paste a PR URL or let the agent create one.")
                    TextField("https://github.com/owner/repo/pull/123", text: $coordinator.manualURL)
                        .textFieldStyle(.roundedBorder)
                        .font(TahoeFont.mono(11.5))
                        .accessibilityLabel("Pull request URL")
                        .accessibilityIdentifier(EmptyActionDescriptors.manualURLAccessibilityIdentifier)
                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m, action: { coordinator.loadFromManualURL() }) {
                            Text(emptyActions.load.title)
                        }
                        .accessibilityIdentifier(emptyActions.load.accessibilityIdentifier)
                        if let create = emptyActions.create, let draft = emptyActions.draft {
                            TahoeGhostButton(size: .m, action: { Task { await coordinator.createPR() } }) {
                                TahoeIcon("pull", size: 11)
                                Text(create.title)
                            }
                            .accessibilityIdentifier(create.accessibilityIdentifier)
                            TahoeGhostButton(size: .m, action: { enqueueDraftPRPrompt() }) {
                                TahoeIcon("doc", size: 11)
                                Text(draft.title)
                            }
                            .accessibilityIdentifier(draft.accessibilityIdentifier)
                        }
                    }
                    .accessibilityIdentifier(EmptyActionDescriptors.rootAccessibilityIdentifier)
                }
                if coordinator.isRefreshing || coordinator.isMutating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("code.pr.progress")
                }
                if let err = coordinator.lastError ?? localActionError {
                    Text(err)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("code.pr.error")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { coordinator.startWatching() }
        .onDisappear { coordinator.stopWatching() }
    }

    private func prStatusRow(_ descriptor: StatusRowDescriptor) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(descriptor.passed ? SessionsV2Theme.success : SessionsV2Theme.warn)
                .frame(width: 14, height: 14)
                .overlay {
                    if descriptor.passed {
                        TahoeIcon("check", size: 8, weight: .bold).foregroundStyle(.white)
                    }
                }
            Text(descriptor.title)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg)
            Spacer()
            Text(descriptor.status)
                .font(TahoeFont.mono(11))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier(descriptor.accessibilityIdentifier)
    }

    private func prCheckRow(_ check: PRCheckMirror) -> some View {
        let descriptor = Self.checkRowDescriptor(check)
        return HStack(spacing: 8) {
            Circle()
                .fill(check.state == .success ? Color.green : (check.state == .failure ? Color.red : Color.yellow))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.name)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if let url = descriptor.url {
                    Text(url)
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(descriptor.state)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
        }
        .padding(.vertical, 5)
        .accessibilityIdentifier(CheckRowDescriptor.rowAccessibilityIdentifier)
        .contextMenu {
            if let open = descriptor.open, let raw = descriptor.url, let url = URL(string: raw) {
                Button(open.title) { NSWorkspace.shared.open(url) }
                    .accessibilityIdentifier(open.accessibilityIdentifier)
            }
            Button(descriptor.copyName.title) { copy(descriptor.name) }
                .accessibilityIdentifier(descriptor.copyName.accessibilityIdentifier)
            if let rerun = descriptor.rerun, let runID = Self.runID(from: descriptor.url) {
                Button(rerun.title) { Task { await rerunCheck(runID: runID, state: coordinator.snapshot) } }
                    .accessibilityIdentifier(rerun.accessibilityIdentifier)
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
        for runID in Self.failedCheckRunIDs(in: state) {
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

    static func failedCheckRunIDs(in state: PRCoordinator.Snapshot) -> [String] {
        state.checks
            .filter { $0.state == .failure }
            .compactMap { runID(from: $0.url) }
    }

    static func runID(from rawURL: String?) -> String? {
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
