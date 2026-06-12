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
    /// Called when the rich model picker chooses a provider + model together.
    /// Pending optimistic sessions use this as launch configuration; regular
    /// live-session swaps still use the model/effort bindings below.
    var onSelectModelConfiguration: ((ProviderChoice, String, ReasoningEffort?) -> Void)?
    /// When set, scopes the model picker rail to a custom provider session.
    var customProviderIdForModelPicker: String? = nil
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
    /// True when the bound view is a read-only transcript. The composer
    /// still renders in a disabled state and hides action chips that require
    /// a live pane.
    var isReadOnly: Bool = false
    /// Collapse the composer to the reference single-row bar
    /// (+ · access · model · effort · send) for the centered empty-state.
    /// The in-session composer keeps the full chrome (defaults false).
    var minimalChrome: Bool = false
    /// Optional override for the text field placeholder.
    var placeholderOverride: String? = nil
    /// When set, shows a provider-account chip (Claude/Codex multi-account)
    /// to the right of the permission-mode chip. nil wireId = primary account.
    var selectedAccountWireId: Binding<String?>? = nil

    struct PrimaryActionDescriptor: Equatable {
        enum Kind: Equatable {
            case send
            case stop
        }

        let kind: Kind
        let isEnabled: Bool
        let accessibilityLabel: String
        let accessibilityIdentifier: String
        let visibleTitle: String?
    }

    struct PendingActionDescriptor: Equatable {
        enum Kind: Equatable {
            case retry
            case dismiss
        }

        let kind: Kind
        let visibleTitle: String?
        let accessibilityIdentifier: String
    }

    struct ModelFailureActionDescriptor: Equatable {
        enum Kind: Equatable {
            case retry
            case retryInNewChat
        }

        let kind: Kind
        let visibleTitle: String
        let accessibilityIdentifier: String
    }

    struct PromptHistoryRowDescriptor: Equatable, Identifiable {
        enum Kind: Equatable {
            case saved(UUID)
            case history
        }

        let kind: Kind
        let title: String
        let body: String
        let accessibilityIdentifier: String

        var id: String { accessibilityIdentifier }
    }

    struct PromptHistoryPresentation: Equatable {
        let savedRows: [PromptHistoryRowDescriptor]
        let historyRows: [PromptHistoryRowDescriptor]
        let showsEmptyHistory: Bool
    }

    static func primaryActionDescriptor(
        isReadOnly: Bool,
        sessionIsRunning: Bool,
        hasInterruptHandler: Bool,
        canSendNow: Bool
    ) -> PrimaryActionDescriptor {
        if !isReadOnly, sessionIsRunning, hasInterruptHandler {
            return PrimaryActionDescriptor(
                kind: .stop,
                isEnabled: true,
                accessibilityLabel: "Stop",
                accessibilityIdentifier: "code.composer.stop",
                visibleTitle: nil
            )
        }
        return PrimaryActionDescriptor(
            kind: .send,
            isEnabled: canSendNow,
            accessibilityLabel: "Send",
            accessibilityIdentifier: "code.composer.send",
            visibleTitle: nil
        )
    }

    static func shouldShowQueueFollowUpButton(
        isReadOnly: Bool,
        sessionIsRunning: Bool,
        hasQueueHandler: Bool
    ) -> Bool {
        !isReadOnly && sessionIsRunning && hasQueueHandler
    }

    static func pendingActionDescriptors(
        for state: OptimisticPendingMessage.State
    ) -> [PendingActionDescriptor] {
        switch state {
        case .sending:
            return []
        case .queuedOffline:
            return [
                PendingActionDescriptor(
                    kind: .retry,
                    visibleTitle: "Retry now",
                    accessibilityIdentifier: "composer.pending.retry"
                ),
                PendingActionDescriptor(
                    kind: .dismiss,
                    visibleTitle: nil,
                    accessibilityIdentifier: "composer.pending.dismiss"
                )
            ]
        case .failed:
            return [
                PendingActionDescriptor(
                    kind: .retry,
                    visibleTitle: "Retry",
                    accessibilityIdentifier: "composer.pending.retry"
                ),
                PendingActionDescriptor(
                    kind: .dismiss,
                    visibleTitle: nil,
                    accessibilityIdentifier: "composer.pending.dismiss"
                )
            ]
        }
    }

    static func modelFailureActionDescriptors() -> [ModelFailureActionDescriptor] {
        [
            ModelFailureActionDescriptor(
                kind: .retry,
                visibleTitle: "Retry",
                accessibilityIdentifier: "transcript.modelFailure.retry"
            ),
            ModelFailureActionDescriptor(
                kind: .retryInNewChat,
                visibleTitle: "Retry in new chat",
                accessibilityIdentifier: "transcript.modelFailure.retryInNewChat"
            )
        ]
    }

    static func textAfterPastingTerminalText(existing: String, rawClipboard: String) -> String {
        let stripped = ClawdmeterTextUtilities.stripANSI(rawClipboard)
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stripped
        }
        var next = existing
        if !next.hasSuffix("\n") {
            next += "\n"
        }
        next += stripped
        return next
    }

    static func canSavePromptText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func promptHistoryRowIdentifier(for body: String) -> String {
        "code.prompt-history.row.\(ClawdmeterTextUtilities.stableContentHash(body))"
    }

    static func savedPromptRowIdentifier(for id: UUID) -> String {
        "code.prompt-history.saved.\(id.uuidString.lowercased())"
    }

    static func promptHistoryPresentation(
        history: [String],
        savedPrompts: [SavedPromptState],
        query: String
    ) -> PromptHistoryPresentation {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let saved = savedPrompts
            .filter { prompt in
                needle.isEmpty
                    || prompt.title.lowercased().contains(needle)
                    || prompt.body.lowercased().contains(needle)
            }
            .map { prompt in
                PromptHistoryRowDescriptor(
                    kind: .saved(prompt.id),
                    title: prompt.title,
                    body: prompt.body,
                    accessibilityIdentifier: savedPromptRowIdentifier(for: prompt.id)
                )
            }
        let rows = history
            .filter { prompt in
                needle.isEmpty || prompt.lowercased().contains(needle)
            }
            .map { prompt in
                PromptHistoryRowDescriptor(
                    kind: .history,
                    title: ClawdmeterTextUtilities.collapsedWhitespacePreview(prompt, limit: 72),
                    body: prompt,
                    accessibilityIdentifier: promptHistoryRowIdentifier(for: prompt)
                )
            }
        return PromptHistoryPresentation(
            savedRows: saved,
            historyRows: rows,
            showsEmptyHistory: rows.isEmpty
        )
    }

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
    /// Drives the running-state accent rim's 1.8s breathing pulse (DESIGN.md
    /// §Motion). Toggled true while a turn runs so the repeatForever animation
    /// oscillates the rim opacity; held false (static rim) under Reduce Motion.
    @State private var rimPulse: Bool = false
    @State private var accountChoices: [ProviderInstanceId] = []
    @ObservedObject private var insertionInbox = ComposerInsertionInbox.shared
    /// Optional: when set, MentionPicker uses these as the source of
    /// suggestions (parent passes session-derived sources + open sessions).
    var mentionSourceProvider: () -> (sessions: [AgentSession], sourceEntries: [SourceEntry]) = { ([], []) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Claude-Code-style stack: input box on top, attachments chip strip,
        // then a single compact bottom bar with all controls + the icon-only
        // send/stop action pinned to the right. The palette / mention popovers
        // float flush ABOVE the composer — attached as an overlay OUTSIDE TahoeGlass (see below),
        // because the glass `.clipShape` was clipping them when they lived
        // inside it.
        TahoeGlass(radius: 8, tone: .raised) {
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
                if !store.browserComments.isEmpty {
                    browserCommentChipsRow
                }
                inputRow
                    .opacity(planApprovalMode ? 0.56 : 1)
                    .disabled(planApprovalMode)
                if minimalChrome {
                    minimalChipRow
                } else {
                    chipRow
                }
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
            // DESIGN.md §Motion: while a turn runs the accent rim *breathes*
            // (1.8s ease-in-out). `rimPulse` oscillates the opacity; under
            // Reduce Motion `composerRimPulse` is nil so we hold a static rim.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(t.accentAlpha(sessionIsRunning ? (reduceMotion ? 0.45 : (rimPulse ? 0.55 : 0.22)) : 0),
                        lineWidth: 1)
                .shadow(color: t.accentAlpha(sessionIsRunning ? (reduceMotion ? 0.28 : (rimPulse ? 0.34 : 0.12)) : 0),
                        radius: 11)
                .allowsHitTesting(false)
        )
        .onChange(of: sessionIsRunning) { _, running in
            if running, let anim = SessionsV2Theme.composerRimPulse(reduceMotion: reduceMotion) {
                rimPulse = false
                withAnimation(anim) { rimPulse = true }
            } else {
                rimPulse = false
            }
        }
        .onAppear {
            if sessionIsRunning, let anim = SessionsV2Theme.composerRimPulse(reduceMotion: reduceMotion) {
                withAnimation(anim) { rimPulse = true }
            }
        }
        // Palette / mention popovers float flush ABOVE the composer. They are
        // attached HERE — outside the inner `TahoeGlass`, whose `.clipShape`
        // was clipping (hiding) them entirely when they sat inside it. The
        // `alignmentGuide(.top){ $0[.bottom] }` shifts each up by its own
        // height so its bottom edge meets the composer's top edge — i.e. it
        // opens right where the user is typing, in every layout (centered
        // empty-state + bottom workbench).
        .overlay(alignment: .topLeading) {
            if showingPalette {
                CommandPaletteView(
                    catalog: skillCatalog,
                    agent: paletteAgent,
                    query: $paletteQuery,
                    onSelect: applyPaletteSelection,
                    onDismiss: { showingPalette = false }
                )
                .alignmentGuide(VerticalAlignment.top) { $0[.bottom] }
                .transition(.opacity)
                .zIndex(2)
            } else if showingMentions {
                let sources = mentionSourceProvider()
                MentionPicker(
                    openSessions: sources.sessions,
                    sourceEntries: sources.sourceEntries,
                    query: $mentionQuery,
                    onSelect: applyMentionSelection,
                    onDismiss: { showingMentions = false }
                )
                .alignmentGuide(VerticalAlignment.top) { $0[.bottom] }
                .transition(.opacity)
                .zIndex(2)
            }
        }
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
        .onChange(of: skillCatalog.commands) { _, _ in
            updatePaletteTriggers(text: store.text)
        }
        .onChange(of: store.agent) { _, _ in
            updatePaletteTriggers(text: store.text)
        }
        .task(id: store.agent) {
            await refreshAccountChoices()
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
        .onReceive(NotificationCenter.default.publisher(for: .composerAttach)) { _ in
            isShowingFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerSetPermissionMode)) { note in
            guard case .emptyState = store.modeKind else { return }
            guard let mode = Self.permissionMode(fromShortcutRaw: note.userInfo?["mode"], availableModes: availablePermissionModes) else {
                return
            }
            onChangePermissionMode?(mode)
        }
        .background(permissionModeShortcutHost)
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

    private var paletteAgent: AgentKind {
        if case .bound = store.modeKind { return agentForModelPicker } else { return store.agent }
    }

    private func paletteCommands(matching query: String) -> [PaletteCommand] {
        skillCatalog.filter(query: query, forAgent: paletteAgent)
    }

    private func updatePaletteTriggers(text: String) {
        // Slash command palette: line starts with '/'.
        if let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last,
           lastLine.hasPrefix("/") {
            let query = String(lastLine.dropFirst())
            paletteQuery = query
            // Agents like Cursor/Grok/OpenCode have no discovered slash
            // commands yet — keep the palette collapsed instead of showing
            // an empty "Slash commands · 0" box.
            showingPalette = !paletteCommands(matching: query).isEmpty
            showingMentions = false
            return
        }
        // @-mention: detect a trailing @<word>, but only when the '@' begins a
        // token (start of text or right after whitespace). Without the boundary
        // check an email like "darshan@axtior" wrongly opened the mention picker.
        if let atRange = text.range(of: "@", options: .backwards),
           atRange.lowerBound == text.startIndex
               || text[text.index(before: atRange.lowerBound)].isWhitespace {
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
        // Insert "/<cmd.id> " in place of the typed "/query" and KEEP the
        // composer open (no auto-send) so the user can add arguments before
        // sending — matches Claude Code's slash-command UX (selection inserts;
        // Enter sends). Auto-sending fired arg-taking skills with no input.
        var lines = store.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty {
            lines.removeLast()
        }
        lines.append("/\(cmd.id) ")
        store.text = lines.joined(separator: "\n")
        showingPalette = false
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
        }
        // Replace only the contiguous "@<query>" token, not through end-of-text:
        // replacing to endIndex clobbered anything the user had typed after the
        // mention (e.g. when the caret was mid-message).
        var tokenEnd = atRange.upperBound
        while tokenEnd < store.text.endIndex, !store.text[tokenEnd].isWhitespace {
            tokenEnd = store.text.index(after: tokenEnd)
        }
        store.text.replaceSubrange(atRange.lowerBound..<tokenEnd, with: replacement)
        showingMentions = false
    }

    // MARK: - Chip row (mode-dependent)

    /// Compact bottom bar — Claude-Code-style single line under the input.
    /// Left cluster: per-turn tools. Right cluster: usage + icon-only action.
    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 8) {
            let resolvedInfo = usageStatus ?? Self.placeholderUsage(modelId: store.modelId, effort: store.effort, catalog: catalog)
            composerToolsMenu
            micButton
            ModelEffortChip(
                info: resolvedInfo,
                catalog: catalog,
                agent: { if case .bound = store.modeKind { return agentForModelPicker } else { return store.agent } }(),
                selectedModelId: $store.modelId,
                selectedEffort: $store.effort,
                modelSupportsEffort: modelSupportsEffort,
                customProviderId: customProviderIdForModelPicker ?? store.customProviderId,
                onSelectAgent: { newAgent in
                    guard case .emptyState = store.modeKind, newAgent != store.agent else { return }
                    store.agent = newAgent
                    store.customProviderId = nil
                    if newAgent == .cursor, store.permissionMode == .plan {
                        onChangePermissionMode?(.ask)
                    }
                },
                onSelectModelConfiguration: { choice, modelId, effort in
                    if onSelectModelConfiguration != nil {
                        store.agent = choice.backingAgent(in: catalog) ?? store.agent
                        store.customProviderId = choice.customProviderId
                    }
                    onSelectModelConfiguration?(choice, modelId, effort)
                }
            )
            .layoutPriority(2)
            if modelSupportsEffort {
                EffortChip(
                    effort: store.effort,
                    supportsEffort: modelSupportsEffort,
                    onChange: { store.effort = $0 }
                )
                .layoutPriority(2)
            }
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
            providerAccountChip
            queueFollowUpButton

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
                // v0.29.31: the standalone provider chip was removed as
                // redundant — the model picker's vendor rail (ModelEffortChip
                // above) now switches provider AND model in one place and maps
                // the picked vendor back to the session agent via onSelectAgent.
                EmptyView()
            }

            Spacer(minLength: 6)

            ContextUsageChip(info: resolvedInfo)
            sendOrStopButton
        }
    }

    /// Reference single-row composer bar for the centered empty-state:
    /// + (attach) · access · ……… · model · effort · send. Drops the
    /// history/saved/strip/expand/mic/usage chrome the bound composer carries.
    @ViewBuilder
    private var minimalChipRow: some View {
        HStack(spacing: 8) {
            plusAttachButton
            if !isReadOnly, onChangePermissionMode != nil {
                PermissionModeChip(
                    mode: permissionMode,
                    availableModes: availablePermissionModes,
                    onChange: { newMode in onChangePermissionMode?(newMode) }
                )
            }
            providerAccountChip
            Spacer(minLength: 8)
            let resolvedInfo = usageStatus ?? Self.placeholderUsage(modelId: store.modelId, effort: store.effort, catalog: catalog)
            ModelEffortChip(
                info: resolvedInfo,
                catalog: catalog,
                agent: { if case .bound = store.modeKind { return agentForModelPicker } else { return store.agent } }(),
                selectedModelId: $store.modelId,
                selectedEffort: $store.effort,
                modelSupportsEffort: modelSupportsEffort,
                customProviderId: customProviderIdForModelPicker ?? store.customProviderId,
                onSelectAgent: { newAgent in
                    guard case .emptyState = store.modeKind, newAgent != store.agent else { return }
                    store.agent = newAgent
                    store.customProviderId = nil
                    if newAgent == .cursor, store.permissionMode == .plan {
                        onChangePermissionMode?(.ask)
                    }
                },
                onSelectModelConfiguration: { choice, modelId, effort in
                    if onSelectModelConfiguration != nil {
                        store.agent = choice.backingAgent(in: catalog) ?? store.agent
                        store.customProviderId = choice.customProviderId
                    }
                    onSelectModelConfiguration?(choice, modelId, effort)
                }
            )
            if modelSupportsEffort {
                EffortChip(
                    effort: store.effort,
                    supportsEffort: modelSupportsEffort,
                    onChange: { store.effort = $0 }
                )
            }
            sendOrStopButton
        }
    }

    @ViewBuilder
    private var permissionModeShortcutHost: some View {
        if !isReadOnly, onChangePermissionMode != nil {
            ZStack {
                ForEach(availablePermissionModes, id: \.self) { mode in
                    Button("") {
                        onChangePermissionMode?(mode)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(PermissionModeChip.shortcutDigit(for: mode)),
                        modifiers: [.command, .shift]
                    )
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private var providerAccountChip: some View {
        if let selectedAccountWireId, accountChoices.count >= 2 {
            ProviderAccountChip(
                accountChoices: accountChoices,
                selectedWireId: selectedAccountWireId.wrappedValue,
                onSelect: { wireId in
                    selectedAccountWireId.wrappedValue = wireId
                    CodeComposerAccountPreference.setWireId(wireId, for: store.agent)
                }
            )
            .layoutPriority(1)
        }
    }

    @MainActor
    private func refreshAccountChoices() async {
        guard selectedAccountWireId != nil else {
            accountChoices = []
            return
        }
        guard let registry = AppDelegate.runtime?.providerInstanceRegistry,
              ProviderInstanceEnvironment.configDirVariable(for: store.agent) != nil else {
            accountChoices = []
            selectedAccountWireId?.wrappedValue = nil
            return
        }
        let choices = await registry.instances(for: store.agent)
        accountChoices = choices
        guard choices.count >= 2 else {
            selectedAccountWireId?.wrappedValue = nil
            return
        }
        if let pinned = selectedAccountWireId?.wrappedValue,
           !choices.contains(where: { $0.wireId == pinned }) {
            selectedAccountWireId?.wrappedValue = nil
        }
        if selectedAccountWireId?.wrappedValue == nil,
           let persisted = CodeComposerAccountPreference.wireId(for: store.agent),
           choices.contains(where: { $0.wireId == persisted }) {
            selectedAccountWireId?.wrappedValue = persisted
        }
    }

    private var plusAttachButton: some View {
        Button(action: { isShowingFileImporter = true }) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(PressableButtonStyle())
        .help("Attach a file or add context")
        .accessibilityIdentifier("code.composer.attach")
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
            contextBreakdown: nil,
            sessionPct: nil,
            sessionResetMins: nil,
            weeklyPct: nil,
            weeklyResetMins: nil,
            cursorQuota: nil
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
        Self.availablePermissionModes(for: agentForModelPicker)
    }

    static func availablePermissionModes(for agent: AgentKind) -> [PermissionMode] {
        if agent == .cursor {
            return [.ask, .acceptEdits, .bypass]
        }
        return [.ask, .acceptEdits, .plan, .bypass]
    }

    static func permissionMode(fromShortcutRaw raw: Any?, availableModes: [PermissionMode]) -> PermissionMode? {
        guard let raw = raw as? String,
              let mode = PermissionMode(rawValue: raw),
              availableModes.contains(mode)
        else {
            return nil
        }
        return mode
    }

    private var enabledModelPickerChoices: [ProviderChoice] {
        ChatV2Store.enabledChatChoices(
            from: ProviderEnablement.enabledProviderIDs(),
            catalog: catalog
        )
    }

    // codeContextChip was deleted in v0.30: PermissionModeChip now does
    // both jobs (click = plan↔code flip via `Menu(primaryAction:)`,
    // long-press = full ask/accept/plan/bypass picker). Two chips for
    // overlapping behavior was the wrong call. Type `@` to open the
    // mention picker (the chip's old "attach code context" entry point).

    /// Claude-Desktop-style "+" overflow menu. Consolidates the former
    /// attach / history / saved-prompts / strip-ANSI / expand icon cluster
    /// into one bottom-left button, so the footer reads as `+  mic  model  effort  …  send`.
    /// Each row keeps its old action + accessibilityIdentifier (UI tests pin
    /// them); ⌥↑ stays on the history row so the shortcut still works. ⌘U
    /// attach arrives via the `.composerAttach` notification, independent of
    /// any button, so it's unaffected. Mic stays a standalone button beside
    /// the "+" (matching the Claude-Desktop +/mic layout).
    private var composerToolsMenu: some View {
        Menu {
            Button { isShowingFileImporter = true } label: {
                Label("Attach File…", systemImage: "paperclip")
            }
            .accessibilityIdentifier("code.composer.attach")

            Button { showingPromptHistory = true } label: {
                Label("Prompt History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .accessibilityIdentifier("code.composer.history")

            Menu {
                if presentationStore.snapshot.savedPrompts.isEmpty {
                    Text("No saved prompts")
                } else {
                    ForEach(presentationStore.snapshot.savedPrompts) { prompt in
                        Button(prompt.title) { store.text = prompt.body }
                            .accessibilityIdentifier(Self.savedPromptRowIdentifier(for: prompt.id))
                    }
                }
                Divider()
                Button("Save Current Prompt…") {
                    savePromptTitle = ClawdmeterTextUtilities.collapsedWhitespacePreview(store.text, limit: 48)
                    showingExpandedEditor = true
                }
                .disabled(store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("code.composer.saved-prompts.save-current")
            } label: {
                Label("Saved Prompts", systemImage: "bookmark")
            }
            .accessibilityIdentifier("code.composer.saved-prompts")

            Divider()

            Button { pasteStrippingANSI() } label: {
                Label("Paste Without ANSI Codes", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("code.composer.paste-ansi")

            Button { showingExpandedEditor = true } label: {
                Label("Expand Editor", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("code.composer.expand")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach, history, saved prompts, and more")
        .accessibilityLabel("Composer tools")
        .accessibilityIdentifier("code.composer.tools-menu")
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 13))
                .foregroundStyle(dictation.state == .recording ? terraCotta : .secondary)
                .symbolEffect(.pulse, isActive: dictation.state == .recording)
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut("m", modifiers: [.control])
        .help(dictationTooltip)
        .accessibilityIdentifier("code.composer.dictation")
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

    private var browserCommentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.browserComments) { comment in
                    BrowserCommentChip(comment: comment) {
                        store.removeBrowserComment(id: comment.id)
                    }
                }
            }
        }
        .frame(maxHeight: 36)
    }

    /// The multi-line composer field. Extracted from `inputRow` so the Swift
    /// type-checker resolves each expression in reasonable time (the inline
    /// chain + onKeyPress closure tripped the "unable to type-check" limit).
    private var composerTextField: some View {
        TextField(textFieldPlaceholder, text: $store.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(TahoeFont.body(14))
            .padding(.horizontal, 0)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .lineLimit(2...18)
            .accessibilityIdentifier("code.composer.input")
            .onKeyPress(.return, phases: .down) { handleReturnKey($0) }
    }

    /// Enter sends; Shift+Return inserts a newline. Fall through (.ignored) when
    /// a completion popover owns Return, mid-IME-composition (commit the CJK
    /// candidate to the field instead of sending), or when Shift is held (the
    /// field inserts a newline at the cursor).
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        if showingPalette || showingMentions { return .ignored }
        // IME guard: when the focused field editor has marked (mid-composition)
        // text, let Return commit the CJK candidate instead of sending.
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        if press.modifiers.contains(.shift) { return .ignored }
        // ⌘↩ (send button) and ⌥↩ (queue follow-up) are AppKit key-equivalents
        // resolved before this handler; never re-interpret a modified Return as
        // a bare send (belt-and-suspenders against a double-send).
        if press.modifiers.contains(.command) || press.modifiers.contains(.option) { return .ignored }
        requestProgrammaticSend()
        return .handled
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                composerTextField
            }
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        dropTargetActive ? t.accent : Color.clear,
                        style: StrokeStyle(lineWidth: dropTargetActive ? 2 : 0)
                    )
            )
            .onDrop(of: [.fileURL, .image, .png, .jpeg, .pdf, .text], isTargeted: $dropTargetActive) { providers in
                handleDrop(providers: providers)
                return true
            }
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        let action = Self.primaryActionDescriptor(
            isReadOnly: isReadOnly,
            sessionIsRunning: sessionIsRunning,
            hasInterruptHandler: onInterrupt != nil,
            canSendNow: canSendNow
        )
        if action.kind == .stop, let onInterrupt {
            Button(action: onInterrupt) {
                ZStack {
                    Circle()
                        .fill(t.dark ? Color.white.opacity(0.90) : Color.black.opacity(0.86))
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(t.dark ? Color.black : Color.white)
                }
                .frame(width: 34, height: 34)
                .shadow(color: t.accentDeep.color(opacity: 0.18), radius: 5, x: 0, y: 3)
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop the running prompt (⌘.)")
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        } else {
            Button(action: sendCurrentDraft) {
                TahoeIcon("arrowU", size: 15, weight: .bold)
                    .foregroundStyle(action.isEnabled ? .white : t.fg4)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(action.isEnabled
                                  ? LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
                                  : LinearGradient(colors: [t.hair2, t.hair2], startPoint: .top, endPoint: .bottom))
                    )
                    .shadow(color: action.isEnabled ? t.accentDeep.color(opacity: 0.30) : .clear, radius: 6, x: 0, y: 4)
                    .symbolEffect(.pulse, isActive: store.isSending)
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!action.isEnabled)
            .help(planApprovalMode ? "Approve or refine the plan above" : "Send (↩ · ⇧↩ for newline)")
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var queueFollowUpButton: some View {
        if Self.shouldShowQueueFollowUpButton(
            isReadOnly: isReadOnly,
            sessionIsRunning: sessionIsRunning,
            hasQueueHandler: onQueue != nil
        ) {
            Button(action: queueCurrentDraft) {
                Image(systemName: store.isSending ? "tray.and.arrow.down" : "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(store.canSend && !store.isSending ? t.accent : t.fg3)
                    .frame(width: 28, height: 28)
                    .background(t.hair2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .keyboardShortcut(.return, modifiers: [.option])
            .disabled(!store.canSend || store.isSending)
            .help("Queue follow-up (⌥↩)")
            .accessibilityLabel("Queue follow-up")
            .accessibilityIdentifier("code.composer.queue-follow-up")
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
        let trimmed = store.draftPayload().render().trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentRefs = store.attachments.map { $0.displayName }
        // Skip when there's literally nothing to render — matches
        // `ComposerStore.canSend` semantics.
        guard !trimmed.isEmpty || !attachmentRefs.isEmpty || !store.browserComments.isEmpty else { return }
        chatStore.injectPending(text: trimmed, attachmentRefs: attachmentRefs)
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
        store.text = Self.textAfterPastingTerminalText(existing: store.text, rawClipboard: raw)
    }

    private func toggleDictation() {
        if dictation.state == .recording {
            dictation.stop()
        } else if case .denied = dictation.state {
            // Permission was previously denied — route to the matching pane.
            dictation.openPrivacySettings()
        } else {
            composerTextBeforeDictation = store.text
            Task { await dictation.start() }
        }
    }

    private var dictationTooltip: String {
        switch dictation.state {
        case .recording: return "Stop dictation (Ctrl+M)"
        case .requestingPermission: return "Requesting permission…"
        case .denied(let r): return "\(r) Click to open System Settings."
        case .unavailable(let r): return r
        case .idle: return "Dictate (Ctrl+M)"
        }
    }

    private var textFieldPlaceholder: String {
        if let placeholderOverride {
            return placeholderOverride
        }
        switch store.modeKind {
        case .bound:
            if sessionIsRunning && onQueue != nil {
                return "Queue a follow-up while this turn runs   (↩)"
            }
            return "What would you like to build today?"
        case .emptyState:
            return "Do anything"
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

private struct PromptHistorySheet: View {
    let history: [String]
    let savedPrompts: [SavedPromptState]
    let onUse: (String) -> Void
    let onDeleteSaved: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @Environment(\.tahoe) private var t

    private var presentation: ComposerInputCore.PromptHistoryPresentation {
        ComposerInputCore.promptHistoryPresentation(
            history: history,
            savedPrompts: savedPrompts,
            query: query
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.fg3)
                    .accessibilityIdentifier("code.prompt-history.sheet")
                TextField("Search prompts", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("code.prompt-history.search")
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("code.prompt-history.done")
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !presentation.savedRows.isEmpty {
                        sectionHeader("Saved")
                        ForEach(presentation.savedRows) { row in
                            promptRow(row)
                        }
                    }
                    sectionHeader("History")
                    if presentation.showsEmptyHistory {
                        Text("No prompt history")
                            .font(TahoeFont.body(12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("code.prompt-history.empty")
                    } else {
                        ForEach(presentation.historyRows) { row in
                            promptRow(row)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TahoeFont.body(11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func promptRow(_ row: ComposerInputCore.PromptHistoryRowDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(TahoeFont.body(12, weight: .semibold))
                .lineLimit(1)
            Text(ClawdmeterTextUtilities.collapsedWhitespacePreview(row.body, limit: 120))
                .font(TahoeFont.body(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            onUse(row.body)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title) \(row.body)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .contextMenu {
            Button("Use Prompt") { onUse(row.body) }
            Button("Copy Prompt") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.body, forType: .string)
            }
            if case .saved(let id) = row.kind {
                Button("Delete Saved Prompt", role: .destructive) {
                    onDeleteSaved(id)
                }
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
                    .accessibilityIdentifier("code.composer.expanded-editor")
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("code.composer.expanded.done")
            }
            TextField("Prompt body", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TahoeFont.body(13))
                .focused($editorFocused)
                .lineLimit(12...40)
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("code.composer.expanded.input")
            HStack(spacing: 8) {
                TextField("Saved prompt title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("code.composer.expanded.title")
                Button("Save Prompt", action: onSavePrompt)
                    .disabled(!ComposerInputCore.canSavePromptText(text))
                    .accessibilityIdentifier("code.composer.expanded.save-prompt")
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { editorFocused = true }
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
    // C2 — was `@ObservedObject var chatStore: SessionChatStore`
    // pre-C2. With the store now `@Observable`, the wrapper drops
    // away: SwiftUI's `withObservationTracking` automatically picks
    // up the `chatStore.pendingMessage` reads inside `body` and
    // re-invalidates only this view when the pending slot mutates.
    let chatStore: SessionChatStore
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
            : ClawdmeterMac_displaySkillInvocations(in: pending.body)
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
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        let pendingActions = ComposerInputCore.pendingActionDescriptors(for: pending.state)
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
                        .foregroundStyle(SessionsV2Theme.warn)
                    Text(pending.errorDescription ?? "Will send when daemon returns")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.warn)
                }
                if let retry = pendingActions.first(where: { $0.kind == .retry }) {
                    Button(retry.visibleTitle ?? "Retry now") { onRetry() }
                        .buttonStyle(PressableButtonStyle())
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .accessibilityIdentifier(retry.accessibilityIdentifier)
                }
                if let dismiss = pendingActions.first(where: { $0.kind == .dismiss }) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(t.fg4)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Discard pending message")
                    .accessibilityIdentifier(dismiss.accessibilityIdentifier)
                }
            case .failed:
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.danger)
                    Text(pending.errorDescription ?? "Failed to send")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(SessionsV2Theme.danger)
                        .lineLimit(2)
                }
                if let retry = pendingActions.first(where: { $0.kind == .retry }) {
                    Button(retry.visibleTitle ?? "Retry") { onRetry() }
                        .buttonStyle(PressableButtonStyle())
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .accessibilityIdentifier(retry.accessibilityIdentifier)
                }
                if let dismiss = pendingActions.first(where: { $0.kind == .dismiss }) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(t.fg4)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Discard pending message")
                    .accessibilityIdentifier(dismiss.accessibilityIdentifier)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }

    private func bubbleFill(_ pending: SessionChatStore.PendingMessage) -> Color {
        switch pending.state {
        case .sending:        return t.hair2
        case .queuedOffline:  return SessionsV2Theme.warn.opacity(0.08)
        case .failed:         return SessionsV2Theme.danger.opacity(0.12)
        }
    }

    private func bubbleStroke(_ pending: SessionChatStore.PendingMessage) -> Color {
        switch pending.state {
        case .sending:        return t.accentAlpha(0.35)
        case .queuedOffline:  return SessionsV2Theme.warn.opacity(0.55)
        case .failed:         return SessionsV2Theme.danger.opacity(0.55)
        }
    }

    private func accessibilityLabel(_ pending: SessionChatStore.PendingMessage) -> String {
        let body = ClawdmeterMac_displaySkillInvocations(in: pending.body)
        switch pending.state {
        case .sending:        return "Sending message: \(body)"
        case .queuedOffline:  return "Queued offline: \(body)"
        case .failed:         return "Failed to send: \(body). \(pending.errorDescription ?? "")"
        }
    }
}
