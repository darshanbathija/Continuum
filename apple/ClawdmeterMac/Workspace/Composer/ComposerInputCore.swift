import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClawdmeterShared

/// Shared chip-row + text input + paperclip + mic core for the two composer
/// surfaces. Reads/writes through a `ComposerStore`; the parent view owns
/// the send action.
///
/// Chip row contents depend on the store's `Mode`:
/// - `.bound(session)` → ModePicker / ModelPicker / EffortDial /
///   AutopilotChip / Stop or Approve button.
/// - `.emptyState(repo, agent)` → repo picker / agent picker / ModelPicker /
///   EffortDial / ModePicker / PlanMode toggle.
///
/// Drag-drop, file-import, and clipboard image paste land here so every
/// composer benefits.
struct ComposerInputCore: View {

    @ObservedObject var store: ComposerStore
    @ObservedObject var presentationStore: SessionPresentationStore
    let catalog: ModelCatalog
    let agentForModelPicker: AgentKind
    let modelSupportsEffort: Bool
    var availableAgents: [AgentKind] = [.claude, .codex, .gemini, .cursor]
    let onSend: () -> Void
    /// Queue delegate. Bound running sessions use this to stage a follow-up
    /// without interrupting the active turn.
    var onQueue: (() -> Void)?
    /// Stop-or-send delegate. When non-nil and the bound session is running,
    /// the send button transforms into a stop button that calls this.
    var onInterrupt: (() -> Void)?
    /// Toggle handler for autopilot (T12). Shown only when set.
    /// Legacy hook — `onChangePermissionMode` supersedes it for the new
    /// PermissionModeChip but the autopilot confirm sheet still routes
    /// through this callback when `.bypass` is picked.
    var onToggleAutopilot: (() -> Void)?
    /// Called when the user picks a new permission mode from the chip.
    /// Bound sessions trigger a respawn via SessionConfigChanger;
    /// empty-state composers just record the choice for the next spawn.
    var onChangePermissionMode: ((PermissionMode) -> Void)?
    /// Resolved permission mode for the chip. For bound sessions this
    /// comes from `PermissionModeStore.currentMode(for:)`. For empty
    /// state it's `store.permissionMode`.
    var permissionMode: PermissionMode = .ask
    /// Approve-plan delegate (Wave A). Shown when the session has plan text.
    var onApprovePlan: (() -> Void)?
    /// "Approve plan" should appear iff the bound session has plan text.
    var showApprovePlan: Bool = false
    /// True when the bound session is actively running (drives stop button).
    var sessionIsRunning: Bool = false
    /// True when the bound view is a synthetic read-only Recent-JSONL row.
    /// The composer still renders, but the send path implicitly promotes
    /// the synthetic to a live `--resume` spawn before posting. Hides
    /// autopilot + approve-plan chips because the synthetic has no pane.
    var isReadOnly: Bool = false

    @StateObject private var dictation = SpeechDictation()
    @ObservedObject private var skillCatalog = SkillCatalog.shared
    @State private var composerTextBeforeDictation: String = ""
    @State private var isShowingFileImporter: Bool = false
    @State private var dropTargetActive: Bool = false
    @State private var showingPalette: Bool = false
    @State private var paletteQuery: String = ""
    @State private var showingMentions: Bool = false
    @State private var mentionQuery: String = ""
    @State private var showingPromptHistory: Bool = false
    @State private var showingExpandedEditor: Bool = false
    @State private var savePromptTitle: String = ""
    @ObservedObject private var insertionInbox = ComposerInsertionInbox.shared
    /// Optional: when set, MentionPicker uses these as the source of
    /// suggestions (parent passes session-derived sources + open sessions).
    var mentionSourceProvider: () -> (sessions: [AgentSession], sourceEntries: [SourceEntry], recents: [RecentSession]) = { ([], [], []) }
    /// Optional: structured context + plan-usage data for the right-side
    /// status chip. When nil the chip is hidden.
    var usageStatus: UsageStatusInfo?
    /// Project-local skill root, if any (`<repo>/.claude/skills/`).
    var projectSkillsRoot: URL?
    /// A13 (perf — optimistic composer UI): the bound session's chat
    /// store. When non-nil, the composer injects an optimistic
    /// `PendingMessage` synchronously on the user's send tap so the
    /// pending bubble renders within 1 frame. Reconciliation, rejection
    /// chip, retry, and the offline queue all flow through this store's
    /// `pendingMessage` slot. Nil for empty-state composers (no chat
    /// store exists yet — the spawn produces one as a side effect of
    /// `firstSend()`).
    var chatStore: SessionChatStore?
    /// A13 — fires when the user taps Retry on a failed pending bubble.
    /// Parent re-runs the same send path; the store is flipped back to
    /// `.sending` so the bubble doesn't flicker out and back in. Nil =
    /// no retry chip rendered.
    var onRetryPending: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tahoe) private var t

    var body: some View {
        // Claude-Code-style stack: input box on top, attachments chip strip,
        // then a single compact bottom bar with all controls + the usage
        // chip on the right. The palette / mention popovers float ABOVE the
        // input row (negative Y offset) as before.
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(spacing: 6) {
                // A13 — optimistic pending bubble strip. Renders as a row
                // above the input box so the user sees an immediate echo of
                // their tap. Hidden when there's no chat store (empty-state
                // composer) or no pending message in flight.
                if let chatStore {
                    PendingMessageStrip(
                        chatStore: chatStore,
                        onRetry: { onRetryPending?() },
                        onDismiss: { chatStore.clearPending() }
                    )
                }
                if !store.attachments.isEmpty {
                    attachmentChipsRow
                }
                inputRow
                    .opacity(planApprovalMode ? 0.56 : 1)
                    .disabled(planApprovalMode)
                    .overlay(alignment: .topLeading) {
                        if showingPalette {
                            CommandPaletteView(
                                catalog: skillCatalog,
                                agent: store.agent,
                                query: $paletteQuery,
                                onSelect: applyPaletteSelection,
                                onDismiss: { showingPalette = false }
                            )
                            .offset(y: -290)
                            .transition(.opacity)
                            .zIndex(2)
                        }
                        if showingMentions {
                            let triple = mentionSourceProvider()
                            MentionPicker(
                                openSessions: triple.sessions,
                                sourceEntries: triple.sourceEntries,
                                recentJSONLs: triple.recents,
                                query: $mentionQuery,
                                onSelect: applyMentionSelection,
                                onDismiss: { showingMentions = false }
                            )
                            .offset(y: -290)
                            .transition(.opacity)
                            .zIndex(2)
                        }
                    }
                chipRow
                if let err = store.lastError {
                    Text(err.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case let .denied(reason) = dictation.state {
                    Text(reason).font(.system(size: 10)).foregroundStyle(.red)
                } else if case let .unavailable(reason) = dictation.state {
                    Text(reason).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(sessionIsRunning ? t.accentAlpha(0.45) : .clear, lineWidth: 1)
                .shadow(color: sessionIsRunning ? t.accentAlpha(0.30) : .clear, radius: 11)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .onReceive(dictation.$partialTranscript) { newPartial in
            guard dictation.state == .recording, !newPartial.isEmpty else { return }
            let base = composerTextBeforeDictation
            store.text = base.isEmpty ? newPartial : "\(base) \(newPartial)"
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawdmeterInsertComposerText)) { note in
            guard let inserted = note.userInfo?["text"] as? String else { return }
            applyExternalInsertion(text: inserted, autoSend: note.userInfo?["send"] as? Bool == true)
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.image, .pdf, .text, .data, .plainText, .sourceCode],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: store.text) { _, new in
            updatePaletteTriggers(text: new)
            persistDraft(new)
        }
        .onAppear {
            skillCatalog.projectSkillsRoot = projectSkillsRoot
            skillCatalog.refreshIfStale()
            restoreDraftIfNeeded()
            consumePendingInsertion()
        }
        .onChange(of: insertionInbox.pendingRequest?.id) { _, _ in
            consumePendingInsertion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerHistory)) { _ in
            showingPromptHistory = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerSend)) { _ in
            requestProgrammaticSend()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerQueue)) { _ in
            queueCurrentDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerToggleDictation)) { _ in
            toggleDictation()
        }
        .sheet(isPresented: $showingPromptHistory) {
            PromptHistorySheet(
                history: presentationStore.snapshot.promptHistory,
                savedPrompts: presentationStore.snapshot.savedPrompts,
                onUse: { prompt in
                    store.text = prompt
                    showingPromptHistory = false
                },
                onDeleteSaved: { id in
                    try? presentationStore.deleteSavedPrompt(id)
                },
                onDismiss: { showingPromptHistory = false }
            )
        }
        .sheet(isPresented: $showingExpandedEditor) {
            ExpandedComposerEditor(
                text: $store.text,
                title: $savePromptTitle,
                onSavePrompt: {
                    try? presentationStore.savePrompt(title: savePromptTitle, body: store.text)
                    savePromptTitle = ""
                },
                onClose: { showingExpandedEditor = false }
            )
        }
    }

    // MARK: - Palette/mention trigger detection

    private func updatePaletteTriggers(text: String) {
        // Slash command palette: line starts with '/'.
        if let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last,
           lastLine.hasPrefix("/") {
            let query = String(lastLine.dropFirst())
            paletteQuery = query
            showingPalette = true
            showingMentions = false
            return
        }
        // @-mention: detect the trailing @<word> in the text.
        if let atRange = text.range(of: "@", options: .backwards) {
            let afterAt = String(text[atRange.upperBound...])
            if !afterAt.contains(" "), !afterAt.contains("\n") {
                mentionQuery = afterAt
                showingMentions = true
                showingPalette = false
                return
            }
        }
        showingPalette = false
        showingMentions = false
    }

    private func applyPaletteSelection(_ cmd: PaletteCommand) {
        // Replace the current last line ("/foo") with "/<cmd.id>". onSend()
        // below appends the terminal newline (ComposerStore.renderPromptBody).
        var lines = store.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty {
            lines.removeLast()
        }
        lines.append("/\(cmd.id)")
        store.text = lines.joined(separator: "\n")
        showingPalette = false
        requestProgrammaticSend()
    }

    private func applyMentionSelection(_ pick: MentionPicker.Suggestion) {
        // Replace the trailing "@<query>" with "@<resolved>".
        guard let atRange = store.text.range(of: "@", options: .backwards) else {
            showingMentions = false
            return
        }
        let replacement: String
        switch pick {
        case .session(let s):
            replacement = "@session:\(s.id.uuidString) "
        case .file(let path, _):
            replacement = "@\(path) "
        case .recent(let r):
            replacement = "@\(r.path) "
        }
        store.text.replaceSubrange(atRange.lowerBound..<store.text.endIndex, with: replacement)
        showingMentions = false
    }

    // MARK: - Chip row (mode-dependent)

    /// Compact bottom bar — Claude-Code-style single line under the input.
    /// Left cluster: per-turn tools (autopilot, attach, mic, mode, plan).
    /// Right cluster: model + effort + usage in a single unified chip that
    /// opens a Claude-Code-style "Models / Effort / Usage" popover.
    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 8) {
            let resolvedInfo = usageStatus ?? Self.placeholderUsage(modelId: store.modelId, effort: store.effort, catalog: catalog)
            ModelEffortChip(
                info: resolvedInfo,
                catalog: catalog,
                agent: { if case .bound = store.modeKind { return agentForModelPicker } else { return store.agent } }(),
                selectedModelId: $store.modelId,
                selectedEffort: $store.effort,
                modelSupportsEffort: modelSupportsEffort
            )
            .layoutPriority(2)
            if !isReadOnly, onChangePermissionMode != nil {
                // v0.7.12 revert: `PermissionModeChip` Menu (matches
                // Claude Code's compact "Auto ▾" pattern — single
                // labeled button that opens a Mode dropdown with
                // numbered ⇧⌘<N> shortcuts and a checkmark on the
                // active row). The v0.7.11 segmented variant was
                // too horizontally heavy; keep the menu and let the
                // chip color encode the active mode at a glance.
                PermissionModeChip(
                    mode: permissionMode,
                    availableModes: availablePermissionModes,
                    onChange: { newMode in
                        onChangePermissionMode?(newMode)
                    }
                )
                .layoutPriority(1)
            }
            attachButton
            codeContextChip
            historyButton
            savedPromptsMenu
            stripANSIPasteButton
            expandEditorButton
            micButton

            switch store.modeKind {
            case .bound:
                // v0.7.9: ModePicker removed. Worktree is the only mode
                // new sessions land in (every session gets its own city-
                // named branch); Local stays in the enum for back-compat
                // with persisted v3 sessions. Mid-session Mode swap is
                // still possible via the Session detail header for the
                // edge cases where a user explicitly wants to move into
                // the primary checkout.
                EmptyView()
            case .emptyState:
                // v0.7.10: agent toggle resets the model + effort to
                // the picked agent's defaults so the chip below the
                // composer (`Opus 4.7 (1M) · Max` etc.) reflects the
                // active agent instead of stale Claude defaults when
                // the user switches to Codex / Gemini.
                AgentMenuChip(
                    selected: store.agent,
                    availableAgents: availableAgents,
                    onSelect: { newAgent in
                        guard newAgent != store.agent else { return }
                        store.resetChipsForAgent(newAgent, catalog: catalog)
                        if newAgent == .cursor, store.permissionMode == .plan {
                            onChangePermissionMode?(.ask)
                        }
                    }
                )
            }

            Spacer(minLength: 6)

            ContextUsageChip(info: resolvedInfo)
        }
    }

    /// Synthesise a `UsageStatusInfo` when the parent didn't supply one —
    /// happens on the empty-state composer (no chat snapshot yet) and on
    /// bound sessions before the first assistant turn lands. The chip still
    /// needs to render so the user can change model/effort.
    private static func placeholderUsage(modelId: String?, effort: ReasoningEffort?, catalog: ModelCatalog) -> UsageStatusInfo {
        let entry = modelId.flatMap { catalog.entry(forId: $0) }
        return UsageStatusInfo(
            modelDisplay: entry?.displayName ?? modelId ?? "Select model",
            effortDisplay: effort.map(effortLabel),
            contextUsedTokens: 0,
            contextLimitTokens: entry?.contextWindow,
            costDollar: 0,
            sessionPct: nil,
            sessionResetMins: nil,
            weeklyPct: nil,
            weeklyResetMins: nil
        )
    }

    private static func effortLabel(_ e: ReasoningEffort) -> String {
        switch e {
        case .minimal: return "Minimal"
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .xhigh:   return "Extra high"
        case .max:     return "Max"
        }
    }

    /// Permission modes available in this composer context. Both
    /// bound + empty-state composers get the full set including
    /// `.bypass`. v0.7.16 wired the empty-state path through
    /// `EmptyStateCenteredComposer.firstSend()`, which records
    /// per-repo trust via `AutopilotState.trustRepo` + seeds
    /// `PermissionModeStore.setBypass` before the spawn — so picking
    /// Bypass at empty-state has the same effect as picking it on a
    /// bound session: the spawned CLI gets `--dangerously-skip-permissions`
    /// (Claude) / `--dangerously-bypass-approvals-and-sandbox` (Codex)
    /// / `--approval-mode yolo` (Gemini).
    private var availablePermissionModes: [PermissionMode] {
        if agentForModelPicker == .cursor {
            return [.ask, .acceptEdits, .bypass]
        }
        return [.ask, .acceptEdits, .plan, .bypass]
    }

    private var attachButton: some View {
        Button(action: { isShowingFileImporter = true }) {
            Image(systemName: "paperclip")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach a file (drag-drop, paste, or click)")
    }

    private var codeContextChip: some View {
        Button(action: { showingMentions = true }) {
            HStack(spacing: 5) {
                TahoeIcon("code", size: 11)
                Text("code")
                    .font(TahoeFont.body(11, weight: .semibold))
            }
            .foregroundStyle(t.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Attach code context")
    }

    private var historyButton: some View {
        Button(action: { showingPromptHistory = true }) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.upArrow, modifiers: [.option])
        .help("Prompt history (⌥↑)")
        .accessibilityLabel("Open prompt history")
    }

    private var savedPromptsMenu: some View {
        Menu {
            if presentationStore.snapshot.savedPrompts.isEmpty {
                Text("No saved prompts")
            } else {
                ForEach(presentationStore.snapshot.savedPrompts) { prompt in
                    Button(prompt.title) { store.text = prompt.body }
                }
            }
            Divider()
            Button("Save Current Prompt…") {
                savePromptTitle = ClawdmeterTextUtilities.collapsedWhitespacePreview(store.text, limit: 48)
                showingExpandedEditor = true
            }
            .disabled(store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved prompts")
        .accessibilityLabel("Saved prompts")
    }

    private var stripANSIPasteButton: some View {
        Button(action: pasteStrippingANSI) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Paste terminal text without ANSI color codes")
        .accessibilityLabel("Paste stripped terminal text")
    }

    private var expandEditorButton: some View {
        Button(action: { showingExpandedEditor = true }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open expanded editor")
        .accessibilityLabel("Open expanded composer editor")
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 13))
                .foregroundStyle(dictation.state == .recording ? terraCotta : .secondary)
                .symbolEffect(.pulse, isActive: dictation.state == .recording)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.control])
        .help(dictationTooltip)
    }

    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.attachments) { att in
                    AttachmentChip(attachment: att) {
                        store.removeAttachment(id: att.id)
                    }
                }
            }
        }
        .frame(maxHeight: 36)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextField(textFieldPlaceholder, text: $store.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(TahoeFont.body(14))
                    .padding(.horizontal, 0)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                    .lineLimit(2...18)
            }
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        dropTargetActive ? t.accent : Color.clear,
                        style: StrokeStyle(lineWidth: dropTargetActive ? 2 : 0)
                    )
            )
            .onDrop(of: [.fileURL, .image, .png, .jpeg, .pdf, .text], isTargeted: $dropTargetActive) { providers in
                handleDrop(providers: providers)
                return true
            }

            sendOrStopButton
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if !isReadOnly, sessionIsRunning, let onInterrupt {
            HStack(spacing: 8) {
                if onQueue != nil {
                    Button(action: queueCurrentDraft) {
                        Image(systemName: store.isSending ? "tray.and.arrow.down" : "tray.and.arrow.down.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(store.canSend && !store.isSending ? t.accent : t.fg3)
                            .frame(width: 28, height: 28)
                            .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.option])
                    .disabled(!store.canSend || store.isSending)
                    .help("Queue follow-up (⌥↩)")
                }
                Button(action: onInterrupt) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(t.dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88))
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(t.dark ? Color.black : Color.white)
                        }
                        .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(liveCostLabel)
                                    .font(TahoeFont.mono(12.5, weight: .bold))
                                Text("● live")
                                    .font(TahoeFont.body(10.5, weight: .semibold))
                                    .foregroundStyle(t.accent)
                            }
                            Text("tap to stop")
                                .font(TahoeFont.body(10))
                                .foregroundStyle(t.fg3)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .frame(height: 34)
                    .background(
                        LinearGradient(colors: [t.accentAlpha(0.18), t.accentAlpha(0.10)], startPoint: .leading, endPoint: .trailing),
                        in: Capsule(style: .continuous)
                    )
                    .overlay(Capsule(style: .continuous).stroke(t.accentAlpha(0.40), lineWidth: 0.75))
                    .foregroundStyle(t.fg)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: [.command])
                .help("Stop the running prompt (⌘.)")
            }
        } else {
            Button(action: sendCurrentDraft) {
                TahoeIcon("arrowU", size: 15, weight: .bold)
                    .foregroundStyle(canSendNow ? .white : t.fg4)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(canSendNow
                                  ? LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
                                  : LinearGradient(colors: [t.hair2, t.hair2], startPoint: .top, endPoint: .bottom))
                    )
                    .shadow(color: canSendNow ? t.accentDeep.color(opacity: 0.30) : .clear, radius: 6, x: 0, y: 4)
                    .symbolEffect(.pulse, isActive: store.isSending)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSendNow)
            .help(planApprovalMode ? "Approve or refine the plan above" : "Send (⌘↩)")
        }
    }

    private var planApprovalMode: Bool {
        !isReadOnly && showApprovePlan
    }

    private var canSendNow: Bool {
        store.canSend && !store.isSending && !planApprovalMode
    }

    private func consumePendingInsertion() {
        guard let id = insertionInbox.pendingRequest?.id,
              let request = insertionInbox.consumePendingRequest(id: id)
        else { return }
        applyExternalInsertion(text: request.text, autoSend: request.autoSend)
    }

    private func applyExternalInsertion(text inserted: String, autoSend: Bool) {
        if store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.text = inserted
        } else {
            if !store.text.hasSuffix("\n") { store.text += "\n" }
            store.text += inserted
        }
        if autoSend {
            requestProgrammaticSend()
        }
    }

    private func requestProgrammaticSend() {
        guard store.canSend else {
            store.endSend(error: .empty)
            return
        }
        guard !store.isSending else { return }
        if planApprovalMode {
            store.endSend(error: .daemonError(message: "Approve or refine the plan before sending."))
            return
        }
        if sessionIsRunning {
            if let onQueue {
                try? presentationStore.recordPrompt(store.text)
                clearPersistedDraft()
                onQueue()
            } else {
                store.endSend(error: .daemonError(message: "This session is running. Stop it before sending another prompt."))
            }
            return
        }
        sendCurrentDraft()
    }

    private func sendCurrentDraft() {
        try? presentationStore.recordPrompt(store.text)
        clearPersistedDraft()
        // A13 — inject the optimistic pending bubble BEFORE the async send
        // call. This is a synchronous mutation on `chatStore.pendingMessage`
        // on the main actor, so SwiftUI flushes the resulting body
        // invalidation on the next runloop tick — within ~16ms of the tap
        // per A13 acceptance.
        injectOptimisticPendingIfWanted()
        onSend()
    }

    private func queueCurrentDraft() {
        guard store.canSend, !store.isSending else { return }
        guard let onQueue else {
            store.endSend(error: .daemonError(message: "No queue target is available for this composer."))
            return
        }
        try? presentationStore.recordPrompt(store.text)
        clearPersistedDraft()
        onQueue()
    }

    /// A13 — synchronous optimistic injection. Mirrors what
    /// `ComposerStore.renderPromptBody` does for prose extraction so the
    /// auto-reconcile on the bound chat store finds a matching body
    /// when the real `user` JSONL line lands. Attachments surface as
    /// `@<basename>` chips in the pending bubble (the chat row renders
    /// the same `@<path>` lines once the daemon writes the JSONL turn,
    /// so the bodies line up).
    ///
    /// No-op when `chatStore` is nil (empty-state composer) — there's
    /// no chat store to render into yet; the empty-state spawn produces
    /// one as a side effect.
    private func injectOptimisticPendingIfWanted() {
        guard let chatStore else { return }
        let trimmed = store.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentRefs = store.attachments.map { $0.displayName }
        // Skip when there's literally nothing to render — matches
        // `ComposerStore.canSend` semantics.
        guard !trimmed.isEmpty || !attachmentRefs.isEmpty else { return }
        chatStore.injectPending(text: trimmed, attachmentRefs: attachmentRefs)
    }

    private var liveCostLabel: String {
        guard let cost = usageStatus?.costDollar else { return "$0.000" }
        return String(format: "$%.3f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    // MARK: - Voice + import + drop + paste handlers

    private var draftPersistenceKey: String {
        switch store.modeKind {
        case .bound(let sessionId):
            return "clawdmeter.composer.draft.\(sessionId.uuidString)"
        case .emptyState:
            return "clawdmeter.composer.draft.empty"
        }
    }

    private func restoreDraftIfNeeded() {
        guard store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let saved = UserDefaults.standard.string(forKey: draftPersistenceKey),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        store.text = saved
    }

    private func persistDraft(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: draftPersistenceKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftPersistenceKey)
        }
    }

    private func clearPersistedDraft() {
        UserDefaults.standard.removeObject(forKey: draftPersistenceKey)
    }

    private func pasteStrippingANSI() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.isEmpty
        else {
            store.endSend(error: .daemonError(message: "Clipboard has no text to paste."))
            return
        }
        let stripped = ClawdmeterTextUtilities.stripANSI(raw)
        if store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.text = stripped
        } else {
            if !store.text.hasSuffix("\n") { store.text += "\n" }
            store.text += stripped
        }
    }

    private func toggleDictation() {
        if dictation.state == .recording {
            dictation.stop()
        } else {
            composerTextBeforeDictation = store.text
            Task { await dictation.start() }
        }
    }

    private var dictationTooltip: String {
        switch dictation.state {
        case .recording: return "Stop dictation (Ctrl+M)"
        case .requestingPermission: return "Requesting permission…"
        case .denied(let r): return r
        case .unavailable(let r): return r
        case .idle: return "Dictate (Ctrl+M)"
        }
    }

    private var textFieldPlaceholder: String {
        switch store.modeKind {
        case .bound:
            if sessionIsRunning && onQueue != nil {
                return "Queue a follow-up while this turn runs   (⌥↩)"
            }
            return "Continue the session here   (⌘↩ to send)"
        case .emptyState:
            if let repo = store.repoKey, !repo.isEmpty {
                let last = (repo as NSString).lastPathComponent
                return "What should we work on in \(last)?"
            }
            return "What should we work on?"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                attach(url: url)
            }
        case .failure(let error):
            store.endSend(error: .daemonError(message: error.localizedDescription))
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.attach(url: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    let data: Data?
                    if let d = item as? Data { data = d }
                    else if let url = item as? URL { data = try? Data(contentsOf: url) }
                    else { data = nil }
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in self.attachImage(image, suggestedName: "pasted.png") }
                }
            }
        }
    }

    private func attach(url: URL) {
        let res = try? url.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
        let size = res?.fileSize ?? 0
        let isImage: Bool = {
            if let typeId = res?.typeIdentifier, let type = UTType(typeId) {
                return type.conforms(to: .image)
            }
            return false
        }()
        do {
            _ = try store.attach(url: url, byteSize: size, isImage: isImage)
        } catch let err as ComposerStore.SendError {
            store.endSend(error: err)
        } catch {
            store.endSend(error: .daemonError(message: error.localizedDescription))
        }
    }

    private func attachImage(_ image: NSImage, suggestedName: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clawdmeter-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: tmp)
            do {
                _ = try store.attach(url: tmp, displayName: suggestedName, byteSize: png.count, isImage: true)
            } catch let err as ComposerStore.SendError {
                store.endSend(error: err)
            }
        } catch {}
    }

    private var composerBg: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

private struct AgentMenuChip: View {
    @Environment(\.tahoe) private var t
    let selected: AgentKind
    let availableAgents: [AgentKind]
    let onSelect: (AgentKind) -> Void

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(availableAgents, id: \.self) { agent in
                    Button {
                        onSelect(agent)
                    } label: {
                        Label(agent.tahoeProvider.displayName, systemImage: agent == selected ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                AgentMenuIcon(provider: selected.tahoeProvider)
                Text(selected.tahoeProvider.displayName)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            .foregroundStyle(t.fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Color.secondary.opacity(0.10), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Choose provider")
    }
}

private struct PromptHistorySheet: View {
    let history: [String]
    let savedPrompts: [SavedPromptState]
    let onUse: (String) -> Void
    let onDeleteSaved: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @Environment(\.tahoe) private var t

    private var filteredHistory: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return history }
        return history.filter { $0.lowercased().contains(needle) }
    }

    private var filteredSavedPrompts: [SavedPromptState] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return savedPrompts }
        return savedPrompts.filter {
            $0.title.lowercased().contains(needle) || $0.body.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.fg3)
                TextField("Search prompts", text: $query)
                    .textFieldStyle(.plain)
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            List {
                if !filteredSavedPrompts.isEmpty {
                    Section("Saved") {
                        ForEach(filteredSavedPrompts) { prompt in
                            promptRow(
                                title: prompt.title,
                                body: prompt.body,
                                action: { onUse(prompt.body) },
                                delete: { onDeleteSaved(prompt.id) }
                            )
                        }
                    }
                }
                Section("History") {
                    if filteredHistory.isEmpty {
                        Text("No prompt history")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredHistory, id: \.self) { prompt in
                            promptRow(
                                title: ClawdmeterTextUtilities.collapsedWhitespacePreview(prompt, limit: 72),
                                body: prompt,
                                action: { onUse(prompt) },
                                delete: nil
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private func promptRow(title: String, body: String, action: @escaping () -> Void, delete: (() -> Void)?) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TahoeFont.body(12, weight: .semibold))
                    .lineLimit(1)
                Text(ClawdmeterTextUtilities.collapsedWhitespacePreview(body, limit: 120))
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Use Prompt", action: action)
            Button("Copy Prompt") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
            }
            if let delete {
                Button("Delete Saved Prompt", role: .destructive, action: delete)
            }
        }
    }
}

private struct ExpandedComposerEditor: View {
    @Binding var text: String
    @Binding var title: String
    let onSavePrompt: () -> Void
    let onClose: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Expanded composer", systemImage: "square.and.pencil")
                    .font(TahoeFont.body(14, weight: .semibold))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            TextEditor(text: $text)
                .font(TahoeFont.body(13))
                .focused($editorFocused)
                .frame(minHeight: 260)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                TextField("Saved prompt title", text: $title)
                    .textFieldStyle(.roundedBorder)
                Button("Save Prompt", action: onSavePrompt)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { editorFocused = true }
    }
}

private struct AgentMenuIcon: View {
    let provider: TahoeProvider

    var body: some View {
        Text(String(provider.displayName.prefix(1)))
            .font(TahoeFont.body(10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(provider.halo.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
    }
}

/// A13 — optimistic pending message strip rendered above the composer
/// input. Surfaces three states:
///   - `.sending` — translucent "Sending…" bubble with a spinner so the
///     user gets an immediate echo of their tap (~16ms).
///   - `.failed` — opaque error bubble with a Retry chip + dismiss. D24
///     acceptance: the bubble stays visible until the user acts.
///   - `.queuedOffline` — same opacity as `.sending` but with an "offline"
///     badge so the user knows the message is staged for replay.
///
/// Border + opacity differ from a confirmed user bubble so a glance
/// distinguishes pending from settled — opacity 0.65 + dashed border for
/// pending, solid + 1.0 opacity once reconciled.
private struct PendingMessageStrip: View {
    @ObservedObject var chatStore: SessionChatStore
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @Environment(\.tahoe) private var t

    var body: some View {
        Group {
            if let pending = chatStore.pendingMessage {
                pendingBubble(pending)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: chatStore.pendingMessage?.id)
        .animation(.easeInOut(duration: 0.18), value: chatStore.pendingMessage?.state)
    }

    @ViewBuilder
    private func pendingBubble(_ pending: SessionChatStore.PendingMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                bodyCard(pending)
                statusRow(pending)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func bodyCard(_ pending: SessionChatStore.PendingMessage) -> some View {
        let body = pending.body.isEmpty
            ? (pending.attachmentRefs.isEmpty
                ? "(empty message)"
                : pending.attachmentRefs.joined(separator: ", "))
            : pending.body
        VStack(alignment: .trailing, spacing: 4) {
            if !pending.attachmentRefs.isEmpty, !pending.body.isEmpty {
                Text(pending.attachmentRefs.joined(separator: " · "))
                    .font(TahoeFont.body(10, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            Text(body)
                .font(TahoeFont.body(13))
                .foregroundStyle(t.fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 520, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    bubbleFill(pending),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            bubbleStroke(pending),
                            style: StrokeStyle(
                                lineWidth: pending.state == .failed ? 1.25 : 0.75,
                                dash: pending.state == .failed ? [] : [4, 3]
                            )
                        )
                )
                .opacity(pending.state == .failed ? 1.0 : 0.65)
                .accessibilityLabel(accessibilityLabel(pending))
        }
    }

    @ViewBuilder
    private func statusRow(_ pending: SessionChatStore.PendingMessage) -> some View {
        HStack(spacing: 8) {
            switch pending.state {
            case .sending:
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Sending…")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                }
            case .queuedOffline:
                HStack(spacing: 5) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(pending.errorDescription ?? "Will send when daemon returns")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.fg3)
                }
                Button("Retry now") { onRetry() }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.accent)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(.plain)
                .help("Discard pending message")
            case .failed:
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(pending.errorDescription ?? "Failed to send")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Button("Retry") { onRetry() }
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityIdentifier("composer.pending.retry")
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.fg4)
                }
                .buttonStyle(.plain)
                .help("Discard pending message")
                .accessibilityIdentifier("composer.pending.dismiss")
            }
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }

    private func bubbleFill(_ pending: SessionChatStore.PendingMessage) -> Color {
        switch pending.state {
        case .sending, .queuedOffline:
            return t.hair2
        case .failed:
            return Color.red.opacity(0.12)
        }
    }

    private func bubbleStroke(_ pending: SessionChatStore.PendingMessage) -> Color {
        switch pending.state {
        case .sending:        return t.accentAlpha(0.35)
        case .queuedOffline:  return Color.orange.opacity(0.55)
        case .failed:         return Color.red.opacity(0.55)
        }
    }

    private func accessibilityLabel(_ pending: SessionChatStore.PendingMessage) -> String {
        switch pending.state {
        case .sending:        return "Sending message: \(pending.body)"
        case .queuedOffline:  return "Queued offline: \(pending.body)"
        case .failed:         return "Failed to send: \(pending.body). \(pending.errorDescription ?? "")"
        }
    }
}
