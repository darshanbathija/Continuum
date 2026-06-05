import SwiftUI
import PhotosUI
import ClawdmeterShared

/// In-flight image attachment on the composer. Held in memory while the
/// upload is in progress + after it completes (so the chip can render
/// the thumbnail). The `remotePath` is the Mac-side absolute path that
/// gets prepended to the prompt as `@<remotePath>` on send.
struct ComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let thumbnailData: Data
    var remotePath: String?
    var uploadError: String?
    var isUploading: Bool
    /// v0.5.2: outside-mode pending payload. Set when the picker stages
    /// an image while the session is still synthetic (no session id to
    /// upload against). `performSend` consumes these on promote and
    /// drives the upload against the new live session id.
    var pendingBytes: Data?
    var pendingExt: String?

    static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
        lhs.id == rhs.id && lhs.remotePath == rhs.remotePath && lhs.isUploading == rhs.isUploading
    }
}

/// Minimal-but-functional chat composer for the iOS Sessions tab.
/// Renders a multi-line text field with "Continue the session here"
/// placeholder + a send arrow. Two modes mirror the Mac:
/// - `.live(sessionId)` — POSTs the prompt to `/sessions/:id/send`.
/// - `.outside(recent, repo)` — POSTs to `/sessions/continue-readonly`
///   (which spawns a live `--resume`/`resume` pane and forwards the
///   prompt as the first turn). Receives the new session id back and
///   notifies the host via `onPromoted` so the open-state can flip from
///   the JSONL path to the live AgentSession.
///
/// Read-only outside sessions stay read-only until the user actually
/// presses Send — tapping in and typing does nothing to the session.
struct iOSComposerBar: View {
    enum Mode {
        case live(session: AgentSession)
        case outside(recent: RecentSession, repo: AgentRepo)
    }

    let mode: Mode
    @ObservedObject var client: AgentControlClient
    /// Notified when a `.outside` send promotes the session to live.
    /// Hosts use this to flip navigation / pop the read-only screen.
    var onPromoted: ((UUID) -> Void)? = nil

    @State private var text: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    /// Image attachments picked from the photo library, currently
    /// uploading or already uploaded. Cleared on successful send.
    @State private var attachments: [ComposerAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingMicNotice: Bool = false
    /// Local mirror of the live session's model + effort so the
    /// composer's pill renders without a round-trip through the daemon.
    /// `onChange` handlers fire the actual respawn via the client.
    @State private var modelId: String?
    @State private var effort: ReasoningEffort?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
            // Card wraps the textfield + the bottom row so the whole
            // composer reads as one control (matches Claude Desktop /
                // Codex screenshots).
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholderText, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .disabled(isSending)

                bottomRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .padding(.top, 6)
        }
        .background(ContinuumTokens.surface2)
        .overlay(alignment: .top) { Divider() }
        .onAppear { syncModelEffortFromSession() }
        .onChange(of: modelId) { _, new in handleModelChange(new) }
        .onChange(of: effort)   { _, new in handleEffortChange(new) }
        .onChange(of: photoPickerItems) { _, newItems in
            // PhotosPicker hands back PhotosPickerItem references. Pull
            // the underlying Data + ingest each one into the attachment
            // list, then clear the picker selection so the same image
            // can be picked twice in a row.
            Task { await ingestPhotoPickerItems(newItems) }
        }
        .alert("Voice dictation coming soon",
               isPresented: $showingMicNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("On-device dictation needs the Speech entitlement — not wired yet. Type or paste for now.")
        }
    }

    /// Horizontal chip strip showing one card per picked attachment.
    /// Tapping the × removes it; the upload state shows as a small
    /// spinner overlay during the daemon round-trip.
    @ViewBuilder
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 70)
    }

    @ViewBuilder
    private func attachmentChip(_ att: ComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let image = UIImage(data: att.thumbnailData) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        )
                }
                if att.isUploading {
                    Color.black.opacity(0.45)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else if att.uploadError != nil {
                    Color.red.opacity(0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
            Button(action: { removeAttachment(att.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .help(att.uploadError ?? att.filename)
    }

    /// Compact bottom row that mirrors the Mac composer's layout:
    /// model+effort pill on the left, mic + attach + send on the right.
    @ViewBuilder
    private var bottomRow: some View {
        HStack(spacing: 8) {
            if case .live(let session) = mode {
                iOSModelEffortPill(
                    agent: session.agent,
                    catalog: client.modelCatalog,
                    selectedModelId: $modelId,
                    selectedEffort: $effort
                )
            } else if case .outside(let recent, _) = mode {
                // Outside rows haven't promoted yet — show the agent
                // they'll spawn with as a static chip so the user knows.
                Text(AgentKindUI.displayName(for: recent.provider))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recent.provider == .claude ? accent : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
            }
            Spacer(minLength: 0)
            attachButton
            micButton
            sendButton
        }
    }

    /// Camera-roll picker. v0.5.2: enabled in BOTH `.live` and `.outside`
    /// modes. Live sessions upload directly to `/sessions/:id/attachments`
    /// as soon as the picker hands back data. Outside rows stage the
    /// payload locally (no upload, no remotePath); `performSend` then
    /// does a two-phase promote → upload → send dance so the user gets
    /// the same single-tap UX in both modes.
    @ViewBuilder
    private var attachButton: some View {
        PhotosPicker(
            selection: $photoPickerItems,
            maxSelectionCount: 4,
            matching: .images
        ) {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Attach photos")
        }
        .photosPickerStyle(.presentation)
    }

    private var micButton: some View {
        Button(action: { showingMicNotice = true }) {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Dictate")
        }
        .buttonStyle(.plain)
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    @MainActor
    private func ingestPhotoPickerItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let picked = items
        // Clear immediately so the same image can be re-picked.
        photoPickerItems = []
        for item in picked {
            // Resolve PNG/JPEG bytes for the thumbnail + upload. Some
            // assets ship as .heic — PhotosPickerItem returns the
            // underlying bytes; the daemon writes them as-is with the
            // ext we detect from the filename.
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = inferExtension(from: data) ?? "jpg"
            let attachmentId = UUID()
            // Pre-thumbnail at 256×256 max to keep the chip layout cheap.
            let thumbData = thumbnail(from: data, max: 256) ?? data
            switch mode {
            case .live(let session):
                // Live sessions: upload immediately. The chip shows a
                // spinner until the daemon writes the file + returns
                // its `~/Library/.../attachments/<sessionId>/...` path.
                attachments.append(ComposerAttachment(
                    id: attachmentId,
                    filename: "screenshot.\(ext)",
                    thumbnailData: thumbData,
                    remotePath: nil,
                    uploadError: nil,
                    isUploading: true,
                    pendingBytes: nil,
                    pendingExt: nil
                ))
                Task {
                    let remote = await client.uploadAttachment(
                        sessionId: session.id, ext: ext, data: data
                    )
                    await MainActor.run {
                        if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                            if let remote {
                                attachments[idx].remotePath = remote
                                attachments[idx].isUploading = false
                            } else {
                                attachments[idx].isUploading = false
                                attachments[idx].uploadError = "Upload failed"
                            }
                        }
                    }
                }
            case .outside:
                // Outside rows: stage the payload locally. We don't have
                // a session id to upload against yet — `performSend`
                // will promote first via `continueReadOnly(prompt: nil)`,
                // THEN upload these bytes against the new session id,
                // THEN call `sendPrompt` with the typed text + the
                // resulting @path references. Chip is presented as
                // "ready" (no spinner) since the upload-on-send dance
                // is implicit.
                attachments.append(ComposerAttachment(
                    id: attachmentId,
                    filename: "screenshot.\(ext)",
                    thumbnailData: thumbData,
                    remotePath: nil,
                    uploadError: nil,
                    isUploading: false,
                    pendingBytes: data,
                    pendingExt: ext
                ))
            }
        }
    }

    /// Best-effort sniff: PNG signature, JPEG SOI, GIF, HEIC. Falls
    /// back to nil so the caller picks a default.
    private func inferExtension(from data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        // HEIC: bytes 4-11 spell "ftypheic" (or heix/heim). Quick check.
        if data.count > 12 {
            let chunk = data.subdata(in: 4..<12)
            if let s = String(data: chunk, encoding: .ascii), s.contains("ftyp") { return "heic" }
        }
        return nil
    }

    /// Downscale a UIImage payload to fit within `max` on either side
    /// for cheap chip rendering. Returns nil if decoding fails.
    private func thumbnail(from data: Data, max maxSide: CGFloat) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let size = img.size
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    private func syncModelEffortFromSession() {
        if case .live(let session) = mode {
            // Seed the pill from the session's current config the first
            // time the composer mounts. After that, onChange handlers
            // own the round-trip.
            if modelId == nil { modelId = session.model }
            if effort  == nil { effort  = session.effort }
        }
    }

    @MainActor
    private func handleModelChange(_ new: String?) {
        guard case .live(let session) = mode,
              let new, new != session.model
        else { return }
        Task {
            await client.changeModel(
                sessionId: session.id,
                request: ChangeModelRequest(model: new, effort: effort)
            )
        }
    }

    @MainActor
    private func handleEffortChange(_ new: ReasoningEffort?) {
        guard case .live(let session) = mode,
              let new, new != session.effort
        else { return }
        Task {
            await client.changeEffort(sessionId: session.id, effort: new)
        }
    }

    private var sendButton: some View {
        Button(action: { Task { await performSend() } }) {
            Group {
                if isSending {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.4))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Send")
        }
        .buttonStyle(.plain)
        .disabled(!canSend || isSending)
    }

    private var canSend: Bool {
        // Allow sending when there's text OR at least one attachment —
        // `@<path>` lines alone are a valid prompt that tells the agent
        // "look at this image". For outside-mode attachments the
        // remotePath isn't set yet (upload happens on send); we count
        // them via `pendingBytes` as ready-to-go.
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyAttachment = attachments.contains {
            $0.remotePath != nil || $0.pendingBytes != nil
        }
        guard hasText || hasReadyAttachment else { return false }
        // Block send while any LIVE-mode attachment is still uploading
        // so we don't drop bytes mid-flight. Outside-mode attachments
        // never have isUploading=true at this point (their upload runs
        // inside performSend after the promote).
        let anyUploading = attachments.contains(where: \.isUploading)
        return !anyUploading
    }

    private var placeholderText: String {
        switch mode {
        case .live:    return "Message the agent…"
        case .outside: return "Continue the session here"
        }
    }

    private var fieldBackground: Color {
        Color(.tertiarySystemBackground)
    }

    private var borderColor: Color { SessionsV2Theme.accent.opacity(0.5) }

    private var accent: Color { SessionsV2Theme.accent }

    @MainActor
    private func performSend() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Build the prompt: `@<path>\n` for each uploaded attachment,
        // then the user's typed text. Mirrors the Mac composer's
        // AttachmentStaging output so the agent's Read tool resolves
        // each file the same way.
        let uploadedPaths = attachments.compactMap(\.remotePath)
        let attachmentPrefix = uploadedPaths.map { "@\($0)" }.joined(separator: "\n")
        let composed: String = {
            if !attachmentPrefix.isEmpty && !trimmed.isEmpty {
                return attachmentPrefix + "\n\n" + trimmed
            } else if !attachmentPrefix.isEmpty {
                return attachmentPrefix
            }
            return trimmed
        }()
        guard !composed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        switch mode {
        case .live(let session):
            await client.sendPrompt(sessionId: session.id, text: composed, asFollowUp: true)
            text = ""
            attachments.removeAll()
        case .outside(let recent, let repo):
            // Two phases when we have attachments staged:
            //   1. continueReadOnly(prompt: nil) — promote the JSONL
            //      to a live --resume pane WITHOUT sending the prompt
            //      yet. Returns the new live session id.
            //   2. uploadAttachment(...) for each pending attachment.
            //      Each upload happens against the new session's
            //      attachments dir on the Mac.
            //   3. sendPrompt(newSessionId, text: <composed-with-paths>)
            //      — fires the actual prompt with @<path> refs to the
            //      just-uploaded files.
            // No-attachment path stays single-shot: continueReadOnly
            // forwards the prompt as the seed turn.
            let hasPending = attachments.contains { $0.pendingBytes != nil }
            if hasPending {
                // Promote-only: nil prompt so the daemon doesn't send
                // anything yet. We'll fire the prompt ourselves once
                // the attachments are uploaded.
                let newSessionId = await client.continueReadOnly(
                    jsonlPath: recent.path,
                    repoKey: repo.key,
                    agent: recent.provider,
                    prompt: nil
                )
                guard let newSessionId else {
                    errorMessage = "Couldn't continue this session — the JSONL header doesn't carry a CLI session id, or the Mac isn't reachable."
                    return
                }
                // Upload each pending attachment in order. Failures get
                // surfaced inline; we still proceed with the successful
                // ones so the user doesn't lose the whole send to one
                // bad image.
                var uploadedPaths: [String] = []
                var anyFailures = false
                for att in attachments {
                    guard let bytes = att.pendingBytes,
                          let ext = att.pendingExt else { continue }
                    if let remote = await client.uploadAttachment(
                        sessionId: newSessionId, ext: ext, data: bytes
                    ) {
                        uploadedPaths.append(remote)
                    } else {
                        anyFailures = true
                    }
                }
                // Rebuild the prompt body with the freshly-resolved
                // @<path> references. We discarded the original
                // attachment-prefix because the paths weren't known
                // when we built `composed` at the top of this func.
                let attachmentPrefix = uploadedPaths.map { "@\($0)" }.joined(separator: "\n")
                let body: String
                if !attachmentPrefix.isEmpty && !trimmed.isEmpty {
                    body = attachmentPrefix + "\n\n" + trimmed
                } else if !attachmentPrefix.isEmpty {
                    body = attachmentPrefix
                } else {
                    body = trimmed
                }
                if !body.isEmpty {
                    await client.sendPrompt(sessionId: newSessionId, text: body, asFollowUp: false)
                }
                text = ""
                attachments.removeAll()
                if anyFailures {
                    errorMessage = "Some attachments failed to upload — the prompt sent without them."
                }
                await client.refreshSessions()
                onPromoted?(newSessionId)
            } else {
                // No attachments: existing single-shot path. continueReadOnly
                // promotes + sends the seed prompt atomically.
                let newSessionId = await client.continueReadOnly(
                    jsonlPath: recent.path,
                    repoKey: repo.key,
                    agent: recent.provider,
                    prompt: composed
                )
                if let newSessionId {
                    text = ""
                    await client.refreshSessions()
                    onPromoted?(newSessionId)
                } else {
                    errorMessage = "Couldn't continue this session — the JSONL header doesn't carry a CLI session id, or the Mac isn't reachable."
                }
            }
        }
    }
}
