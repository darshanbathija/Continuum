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
    var onToggleAutopilot: (() -> Void)?
    /// Approve-plan delegate (Wave A). Shown when the session has plan text.
    var onApprovePlan: (() -> Void)?
    /// "Approve plan" should appear iff the bound session has plan text.
    var showApprovePlan: Bool = false
    /// True when the bound session is actively running (drives stop button).
    var sessionIsRunning: Bool = false

    @StateObject private var dictation = SpeechDictation()
    @State private var composerTextBeforeDictation: String = ""
    @State private var isShowingFileImporter: Bool = false
    @State private var dropTargetActive: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            chipRow
            if !store.attachments.isEmpty {
                attachmentChipsRow
            }
            inputRow
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
    }

    // MARK: - Chip row (mode-dependent)

    @ViewBuilder
    private var chipRow: some View {
        HStack(spacing: 6) {
            switch store.modeKind {
            case .bound:
                ModePicker(mode: store.mode, agent: store.agent) { newMode in
                    store.mode = newMode
                }
                ModelPicker(
                    selectedModelId: store.modelId,
                    catalog: catalog,
                    agent: agentForModelPicker
                ) { entry in
                    store.modelId = entry.id
                }
                EffortDial(selected: store.effort, supportsEffort: modelSupportsEffort) { newEffort in
                    store.effort = newEffort
                }
                if onToggleAutopilot != nil {
                    AutopilotChip(isOn: store.autopilotEnabled) {
                        onToggleAutopilot?()
                    }
                }
                Spacer()
                if showApprovePlan, let onApprovePlan {
                    Button(action: onApprovePlan) {
                        Label("Approve plan", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(terraCotta)
                    .controlSize(.small)
                }
            case .emptyState:
                // Empty-state row: agent + model + effort + mode + plan toggle.
                Picker("Agent", selection: $store.agent) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
                ModelPicker(
                    selectedModelId: store.modelId,
                    catalog: catalog,
                    agent: store.agent
                ) { entry in
                    store.modelId = entry.id
                }
                EffortDial(selected: store.effort, supportsEffort: modelSupportsEffort) { newEffort in
                    store.effort = newEffort
                }
                ModePicker(mode: store.mode, agent: store.agent) { newMode in
                    store.mode = newMode
                }
                Toggle("Plan", isOn: $store.planMode)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Plan mode runs the agent read-only until you approve.")
                Spacer()
            }
        }
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
            Button(action: { isShowingFileImporter = true }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach a file (drag-drop, paste, or click)")

            Button(action: toggleDictation) {
                Image(systemName: dictation.state == .recording ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(dictation.state == .recording ? terraCotta : .secondary)
                    .symbolEffect(.pulse, isActive: dictation.state == .recording)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [.control])
            .help(dictationTooltip)

            TextField(textFieldPlaceholder, text: $store.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(composerBg, in: RoundedRectangle(cornerRadius: 8))
                .lineLimit(1...20)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(dropTargetActive ? terraCotta : Color.clear, lineWidth: 2)
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
        if sessionIsRunning, let onInterrupt {
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
        case .bound: return "Message the agent…  (⌘↩ send)"
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

    private var terraCotta: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}
