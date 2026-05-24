import Foundation
#if canImport(Combine)
import Combine
#endif

/// Composer state model. Sits behind every Mac composer surface
/// (`BoundComposerView` for in-session, `EmptyStateComposerView` for the
/// zero-session dashboard). Pure value-driven state — Views read it,
/// callbacks mutate it, send-on-action is the SwiftUI integration point.
///
/// Lives in `ClawdmeterShared` so it can be unit-tested via the existing
/// `ClawdmeterSharedTests` target (no Mac-only test target exists; the
/// project doesn't ship one — Codex P1 finding 2026-05-18).
@MainActor
public final class ComposerStore: ObservableObject {

    public enum Mode: Equatable, Sendable {
        /// In-session composer: send appends to the bound session's chat.
        case bound(sessionId: UUID)
        /// Empty-state composer: first send spawns a new session, then
        /// posts the prompt as the opening user turn.
        case emptyState(repoKey: String?, agent: AgentKind)
    }

    /// One file attached to the pending message. Stored as a value
    /// alongside `sourceURL` (where the file lives now) and `stagedURL`
    /// (where it'll be copied at send time, if any).
    public struct Attachment: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let sourceURL: URL
        public let displayName: String
        public let byteSize: Int
        public let isImage: Bool

        public init(id: UUID = UUID(), sourceURL: URL, displayName: String, byteSize: Int, isImage: Bool) {
            self.id = id
            self.sourceURL = sourceURL
            self.displayName = displayName
            self.byteSize = byteSize
            self.isImage = isImage
        }
    }

    public enum SendError: LocalizedError, Equatable {
        case empty
        case attachmentTooLarge(name: String)
        case spawnFailed(message: String)
        case daemonError(message: String)
        case unauthorized
        case rateLimited(retryAfter: Int?)
        case sessionGone
        case timeout
        case offline

        public var errorDescription: String? {
            switch self {
            case .empty: return "Type something to send."
            case .attachmentTooLarge(let name): return "File too large (max \(ComposerStore.attachmentMaxBytes / 1_048_576)MB): \(name)"
            case .spawnFailed(let m): return "Couldn't start the session: \(m)"
            case .daemonError(let m): return "Daemon error: \(m)"
            case .unauthorized: return "Re-pair this Mac in Settings → Sessions."
            case .rateLimited(let r): return r.map { "Slow down (retry in \($0)s)." } ?? "Rate-limited."
            case .sessionGone: return "Session ended. Start a new one."
            case .timeout: return "Daemon didn't respond — retrying."
            case .offline: return "Daemon offline. Restart Clawdmeter."
            }
        }
    }

    /// Hard cap before the composer rejects an attachment.
    public nonisolated static let attachmentMaxBytes = 50 * 1_048_576

    // MARK: - Published state

    @Published public var text: String = ""
    @Published public private(set) var attachments: [Attachment] = []
    @Published public var modelId: String?
    @Published public var effort: ReasoningEffort?
    // v0.7.9: every new composer session lands in a worktree by default.
    // The Local/Worktree/Cloud chip has been removed from the UI; the
    // SessionMode enum stays for back-compat with persisted v3 sessions
    // that recorded `.local` before this change.
    @Published public var mode: SessionMode = .worktree
    @Published public var planMode: Bool = false
    @Published public var autopilotEnabled: Bool = false
    /// Claude-Code-style permission mode for the empty-state composer.
    /// Drives the NewSessionRequest's spawn flags. Mirrored to
    /// `planMode`/`autopilotEnabled` via `permissionMode.didSet`-style
    /// glue in callers, so existing code paths keep working without
    /// having to be ported to the new enum.
    @Published public var permissionMode: PermissionMode = .ask
    @Published public var agent: AgentKind = .claude
    @Published public var repoKey: String?
    @Published public private(set) var isSending: Bool = false
    @Published public private(set) var lastError: SendError?
    /// True when palette popovers are active. Views toggle via setters.
    @Published public var commandPaletteVisible: Bool = false
    @Published public var mentionPaletteVisible: Bool = false

    public let modeKind: Mode

    public init(mode: Mode) {
        self.modeKind = mode
        switch mode {
        case .emptyState(let repoKey, let agent):
            self.repoKey = repoKey
            self.agent = agent
        case .bound:
            break
        }
    }

    // MARK: - Attachments

    /// Add a file. Rejects on size cap; on accept, appends the chip.
    /// Returns the new attachment id, or throws SendError.attachmentTooLarge.
    @discardableResult
    public func attach(url: URL, displayName: String? = nil, byteSize: Int, isImage: Bool) throws -> UUID {
        guard byteSize <= Self.attachmentMaxBytes else {
            throw SendError.attachmentTooLarge(name: displayName ?? url.lastPathComponent)
        }
        let att = Attachment(
            sourceURL: url,
            displayName: displayName ?? url.lastPathComponent,
            byteSize: byteSize,
            isImage: isImage
        )
        attachments.append(att)
        return att.id
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    public func clearAttachments() {
        attachments.removeAll()
    }

    // MARK: - Compose flow control

    /// Reset the composer for the next prompt. Keeps chip state.
    public func clearAfterSend() {
        text = ""
        attachments.removeAll()
        lastError = nil
    }

    public func beginSend() {
        isSending = true
        lastError = nil
    }

    public func endSend(error: SendError? = nil) {
        isSending = false
        lastError = error
        if error == nil {
            clearAfterSend()
        }
    }

    /// Reset chip state for a fresh repo. Used by the empty-state composer
    /// when the user changes the repo selector (4A decision).
    public func resetChipsForRepo(_ key: String?, defaults: ChipDefaults) {
        repoKey = key
        agent = defaults.agent
        modelId = defaults.modelId
        effort = defaults.effort
        mode = defaults.mode
        planMode = defaults.planMode
    }

    public struct ChipDefaults: Sendable, Equatable {
        public let agent: AgentKind
        public let modelId: String?
        public let effort: ReasoningEffort?
        public let mode: SessionMode
        public let planMode: Bool
        public init(
            agent: AgentKind = .claude,
            modelId: String? = "claude-opus-4-7-1m",
            effort: ReasoningEffort? = .max,
            mode: SessionMode = .worktree,
            planMode: Bool = false
        ) {
            self.agent = agent
            self.modelId = modelId
            self.effort = effort
            self.mode = mode
            self.planMode = planMode
        }
        public static let `default` = ChipDefaults()

        /// v0.7.10: per-agent default model + effort. Sourced from
        /// `ModelCatalog.bundled` so the catalog stays the single
        /// source of truth — the first entry per agent's `gemini` /
        /// `codex` / `claude` slice is the default. Effort is cleared
        /// for models whose `supportsEffort` is false (Gemini today).
        public static func `for`(agent: AgentKind, catalog: ModelCatalog = .bundled) -> ChipDefaults {
            let entry: ModelCatalogEntry?
            switch agent {
            case .claude: entry = catalog.claude.first
            case .codex:  entry = catalog.codex.first
            case .gemini: entry = catalog.gemini.first
            case .opencode: entry = catalog.opencode.first
            case .cursor: entry = catalog.cursor.first
            case .unknown:
                // X3: forward-compat unknown agent — no catalog slice
                // exists. Composer chips clear; the picker hides the
                // chip until the user selects a known agent.
                entry = nil
            }
            let effort: ReasoningEffort? = (entry?.supportsEffort ?? false) ? .max : nil
            return ChipDefaults(
                agent: agent,
                modelId: entry?.id,
                effort: effort,
                mode: .worktree,
                planMode: false
            )
        }
    }

    /// v0.7.10: flip composer chips to the picked agent's defaults.
    /// Called when the user toggles the agent picker in the composer —
    /// the model chip + effort dial reset so the user doesn't end up
    /// shipping a Codex turn to Gemini.
    public func resetChipsForAgent(_ agent: AgentKind) {
        let defaults = ChipDefaults.for(agent: agent)
        self.agent = agent
        self.modelId = defaults.modelId
        self.effort = defaults.effort
    }

    // MARK: - Output rendering

    /// Compose the final prompt body sent to the daemon. Prepends the
    /// `@<absolute-path>` references for each attachment (per the locked
    /// image-handling decision) and the user's text. **Includes a trailing
    /// newline** because tmux paste-buffer doesn't submit without one
    /// (Codex P0 finding 2026-05-18).
    public func renderPromptBody(attachmentPaths: [URL]) -> String {
        var lines: [String] = []
        for path in attachmentPaths {
            lines.append("@\(path.path)")
        }
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty {
            lines.append(prose)
        }
        // Always terminal newline so tmux paste-buffer commits the prompt.
        return lines.joined(separator: "\n") + "\n"
    }

    /// True iff the composer has any content worth sending.
    public var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}
