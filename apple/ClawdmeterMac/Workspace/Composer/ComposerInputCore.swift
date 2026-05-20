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
    let catalog: ModelCatalog
    let agentForModelPicker: AgentKind
    let modelSupportsEffort: Bool
    let onSend: () -> Void
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
    /// Optional: when set, MentionPicker uses these as the source of
    /// suggestions (parent passes session-derived sources + open sessions).
    var mentionSourceProvider: () -> (sessions: [AgentSession], sourceEntries: [SourceEntry], recents: [RecentSession]) = { ([], [], []) }
    /// Optional: structured context + plan-usage data for the right-side
    /// status chip. When nil the chip is hidden.
    var usageStatus: UsageStatusInfo?
    /// Project-local skill root, if any (`<repo>/.claude/skills/`).
    var projectSkillsRoot: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Claude-Code-style stack: input box on top, attachments chip strip,
        // then a single compact bottom bar with all controls + the usage
        // chip on the right. The palette / mention popovers float ABOVE the
        // input row (negative Y offset) as before.
        VStack(spacing: 6) {
            if !store.attachments.isEmpty {
                attachmentChipsRow
            }
            inputRow
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onReceive(dictation.$partialTranscript) { newPartial in
            guard dictation.state == .recording, !newPartial.isEmpty else { return }
            let base = composerTextBeforeDictation
            store.text = base.isEmpty ? newPartial : "\(base) \(newPartial)"
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
        }
        .onAppear {
            skillCatalog.projectSkillsRoot = projectSkillsRoot
            skillCatalog.refreshIfStale()
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
        onSend()
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
            if !isReadOnly, onChangePermissionMode != nil {
                // v0.7.11: segmented picker matches the Claude/Codex/
                // Gemini agent strip's visual weight. Replaces the
                // compact chip+chevron so the active mode reads at
                // a glance.
                PermissionModeSegmented(
                    mode: permissionMode,
                    availableModes: availablePermissionModes,
                    onChange: { newMode in
                        onChangePermissionMode?(newMode)
                    }
                )
            }
            attachButton
            micButton

            Divider().frame(height: 16).padding(.horizontal, 2)

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
                Picker("Agent", selection: Binding(
                    get: { store.agent },
                    set: { newAgent in
                        guard newAgent != store.agent else { return }
                        store.resetChipsForAgent(newAgent)
                    }
                )) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                    Text("Gemini").tag(AgentKind.gemini)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }

            Spacer(minLength: 6)

            if !isReadOnly, showApprovePlan, let onApprovePlan {
                Button(action: onApprovePlan) {
                    Label("Approve plan", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(terraCotta)
                .controlSize(.small)
            }
            let resolvedInfo = usageStatus ?? Self.placeholderUsage(modelId: store.modelId, effort: store.effort, catalog: catalog)
            // Two-chip split (left = context/usage, right = model/effort) —
            // each opens an independent popover so the user can glance at
            // window utilisation without committing to a model swap.
            ContextUsageChip(info: resolvedInfo)
            ModelEffortChip(
                info: resolvedInfo,
                catalog: catalog,
                agent: { if case .bound = store.modeKind { return agentForModelPicker } else { return store.agent } }(),
                selectedModelId: $store.modelId,
                selectedEffort: $store.effort,
                modelSupportsEffort: modelSupportsEffort
            )
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

    /// Permission modes available in this composer context. Bound
    /// sessions get the full set; empty-state composers hide `.bypass`
    /// (no session yet → nothing to trust-gate).
    private var availablePermissionModes: [PermissionMode] {
        switch store.modeKind {
        case .bound:      return [.ask, .acceptEdits, .plan, .bypass]
        case .emptyState: return [.ask, .acceptEdits, .plan]
        }
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
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .lineLimit(4...24)
            }
            .background(composerBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        dropTargetActive ? terraCotta : terraCotta.opacity(0.45),
                        style: StrokeStyle(lineWidth: dropTargetActive ? 2 : 1, dash: dropTargetActive ? [] : [4, 4])
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
            Button(action: onInterrupt) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(terraCotta)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop the running prompt (⌘.)")
        } else {
            Button(action: onSend) {
                Image(systemName: store.isSending ? "arrow.up.circle" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(store.canSend && !store.isSending ? terraCotta : .secondary)
                    .symbolEffect(.pulse, isActive: store.isSending)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!store.canSend || store.isSending)
            .help("Send (⌘↩)")
        }
    }

    // MARK: - Voice + import + drop + paste handlers

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
