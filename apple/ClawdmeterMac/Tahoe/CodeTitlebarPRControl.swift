import SwiftUI
import AppKit
import ClawdmeterShared

/// Code-tab titlebar control for creating and merging pull requests.
/// Replaces the dedicated PR review pane — PR workflow lives next to the
/// composer via agent prompts plus these one-click titlebar actions.
struct CodeTitlebarPRControl: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var workbenchState: WorkbenchState
    let session: AgentSession
    @ObservedObject private var prMirror: PRMirror
    @ObservedObject private var prCoordinator: PRCoordinator
    @State private var mergeError: String?

    init(model: SessionsModel, workbenchState: WorkbenchState, session: AgentSession) {
        self.model = model
        self.workbenchState = workbenchState
        self.session = session
        _prMirror = ObservedObject(wrappedValue: model.prMirror(for: session))
        _prCoordinator = ObservedObject(wrappedValue: model.prCoordinator(for: session))
    }

    @Environment(\.tahoe) private var t

    var body: some View {
        Group {
            if let pr = resolvedPR {
                prLinkedControls(pr)
            } else if showsCreatePR {
                createPRButton
            }
        }
        .onAppear {
            prMirror.startWatching()
            prCoordinator.startWatching()
            publishCurrentPRCache()
        }
        .onChange(of: prMirror.state) { _, state in
            guard let state else { return }
            recordPRCache(PRCacheStateSnapshot(sessionId: session.id, mirrorState: state))
        }
        .onChange(of: prCoordinator.snapshot) { _, snapshot in
            guard let snapshot else { return }
            recordPRCache(PRCacheStateSnapshot(sessionId: session.id, coordinatorSnapshot: snapshot))
        }
    }

    private var showsCreatePR: Bool {
        guard session.worktreePath != nil else { return false }
        guard !turnIsStreaming else { return false }
        guard CenterThread.shouldSendPromptAsFollowUp(snapshot: chatSnapshot) else { return false }
        return true
    }

    private var createPRButton: some View {
        HStack(spacing: 0) {
            Button(action: ContinuumAnalytics.wrapButton("create_pr", enqueueCreatePRPrompt)) {
                HStack(spacing: 6) {
                    createPRIcon
                    Text("Create PR")
                        .font(TahoeFont.body(12, weight: .semibold))
                }
                .foregroundStyle(t.fg)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 24)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("code.titlebar.create-pr")

            Rectangle()
                .fill(t.hairline)
                .frame(width: 0.5, height: 14)

            Menu {
                Button("Create draft PR", action: ContinuumAnalytics.wrapButton(
                        "create_draft_pr",
                        {

                    enqueueDraftPRPrompt()
                
                        }
                    ))
                .accessibilityIdentifier("code.titlebar.create-pr.draft")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .frame(width: 22, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("code.titlebar.create-pr.menu")
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(t.hairline, lineWidth: 0.5)
        }
        .help("Send the agent a Create PR instruction with PR instructions.md attached")
    }

    private var createPRIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
            Image(systemName: "plus")
                .font(.system(size: 7, weight: .bold))
                .offset(x: -1, y: 1)
        }
        .frame(width: 14, height: 12)
    }

    private func prLinkedControls(_ pr: PRMirror.PRState) -> some View {
        HStack(spacing: 6) {
            Button(action: ContinuumAnalytics.wrapButton(
                    "open_pr",
                    {

                NSWorkspace.shared.open(pr.url)
            
                    }
                )) {
                HStack(spacing: 5) {
                    Text("#\(pr.number)")
                        .font(TahoeFont.mono(12, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(prLinkColor(for: pr.state))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(prLinkColor(for: pr.state).opacity(0.55), lineWidth: 0.5)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .help(pr.title.isEmpty ? "Open pull request" : pr.title)
            .accessibilityIdentifier("code.titlebar.pr.link")

            if pr.state.uppercased() == "OPEN", canMerge {
                Button(action: ContinuumAnalytics.wrapButton(
                        "merge_pr",
                        {

                    Task { await mergePullRequest() }
                
                        }
                    )) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Merge")
                            .font(TahoeFont.body(12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(SessionsV2Theme.success, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(prCoordinator.isMutating)
                .help(mergeHelp)
                .accessibilityIdentifier("code.titlebar.pr.merge")
            }
        }
        .overlay(alignment: .bottom) {
            if let mergeError {
                Text(mergeError)
                    .font(TahoeFont.body(10))
                    .foregroundStyle(.red)
                    .offset(y: 18)
            }
        }
    }

    private var resolvedPR: PRMirror.PRState? {
        prMirror.state
    }

    private func publishCurrentPRCache() {
        if let state = prMirror.state {
            recordPRCache(PRCacheStateSnapshot(sessionId: session.id, mirrorState: state))
        }
        if let snapshot = prCoordinator.snapshot {
            recordPRCache(PRCacheStateSnapshot(sessionId: session.id, coordinatorSnapshot: snapshot))
        }
    }

    private func recordPRCache(_ cache: PRCacheStateSnapshot) {
        let existing = workbenchState.snapshot.prCache[session.id]
        guard existing?.prURL != cache.prURL
            || existing?.state != cache.state
            || existing?.checksConclusion != cache.checksConclusion
            || existing?.updatedAt != cache.updatedAt
        else { return }
        workbenchState.recordPRCache(cache)
    }

    private var chatSnapshot: SessionChatStore.ChatSnapshot? {
        model.chatStore(for: session)?.snapshot
    }

    private var turnIsStreaming: Bool {
        let chatStore = model.chatStore(for: session)
        return CenterThread.hasActiveProviderTurn(
            snapshot: chatStore?.snapshot,
            pendingMessage: chatStore?.pendingMessage
        )
    }

    private var canMerge: Bool {
        guard let snapshot = prCoordinator.snapshot else { return false }
        return PRCoordinator.canMerge(snapshot: snapshot, canUseDaemonActions: prCoordinator.canUseDaemonActions)
            && todoGatePassed
    }

    private var todoGatePassed: Bool {
        (model.chatStore(for: session)?.snapshot.codexTodos ?? [])
            .allSatisfy { $0.status == "completed" }
    }

    private var mergeHelp: String {
        if !todoGatePassed { return "Complete open TODOs before merging." }
        if !canMerge { return "Merge is blocked until checks pass." }
        return "Merge this pull request"
    }

    private func prLinkColor(for state: String) -> Color {
        switch state.uppercased() {
        case "OPEN": return SessionsV2Theme.success
        case "MERGED": return Color(red: 0x8A / 255.0, green: 0x3F / 255.0, blue: 0xFC / 255.0)
        case "CLOSED": return .red
        default: return t.fg2
        }
    }

    private func enqueueCreatePRPrompt() {
        mergeError = nil
        enqueuePRPrompt(text: PRPromptResolver.promptText)
    }

    private func enqueueDraftPRPrompt() {
        mergeError = nil
        enqueuePRPrompt(
            text: "Create a draft PR with a concise title, a tested-change summary, verification steps, and known risks."
        )
    }

    private func enqueuePRPrompt(text: String) {
        guard let instructions = PRPromptResolver.instructionsFileURL(for: session) else {
            mergeError = "PR instructions skill is missing."
            return
        }
        ComposerInsertionInbox.shared.enqueue(
            text: text,
            autoSend: true,
            attachmentURL: instructions,
            attachmentDisplayName: PRPromptResolver.attachmentDisplayName
        )
    }

    @MainActor
    private func mergePullRequest() async {
        mergeError = nil
        guard canMerge else {
            mergeError = todoGatePassed ? "Merge is blocked by checks." : "Complete open TODOs before merging."
            return
        }
        let checkpoint = CheckpointService()
        do {
            let created = try await checkpoint.createCheckpoint(session: session, summary: "Before PR merge")
            workbenchState.recordCheckpoint(created)
        } catch {
            mergeError = "Safety checkpoint failed. Merge cancelled."
            return
        }
        await prCoordinator.merge()
        if let err = prCoordinator.lastError {
            mergeError = err
        }
    }
}
