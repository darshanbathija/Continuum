import Foundation
#if canImport(Combine)
import Combine
#endif

public struct BrowserCommentContext: Codable, Hashable, Identifiable, Sendable {
    public struct BoundingBox: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var id: UUID
    public var urlString: String?
    public var selector: String
    public var snippet: String
    public var comment: String
    public var summary: String
    public var annotationId: String?
    public var selectedText: String?
    public var nearbyText: String?
    public var accessibilityLabel: String?
    public var sourceHint: String?
    public var computedStyleSummary: [String: String]
    public var areaSelection: String?
    public var cssClasses: [String]
    public var boundingBox: BoundingBox?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        urlString: String?,
        selector: String,
        snippet: String,
        comment: String,
        summary: String? = nil,
        annotationId: String? = nil,
        selectedText: String? = nil,
        nearbyText: String? = nil,
        accessibilityLabel: String? = nil,
        sourceHint: String? = nil,
        computedStyleSummary: [String: String] = [:],
        areaSelection: String? = nil,
        cssClasses: [String] = [],
        boundingBox: BoundingBox? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.urlString = Self.redactedLine(urlString ?? "", maxLength: 500).nilIfEmpty
        self.selector = Self.redactedLine(selector, maxLength: 300)
        self.snippet = Self.redactedLine(snippet, maxLength: 1_000)
        self.comment = Self.redactedText(comment, maxLength: 4_000)
        self.annotationId = Self.redactedLine(annotationId ?? "", maxLength: 120).nilIfEmpty
        self.selectedText = Self.redactedLine(selectedText ?? "", maxLength: 1_000).nilIfEmpty
        self.nearbyText = Self.redactedLine(nearbyText ?? "", maxLength: 1_500).nilIfEmpty
        self.accessibilityLabel = Self.redactedLine(accessibilityLabel ?? "", maxLength: 240).nilIfEmpty
        self.sourceHint = Self.redactedLine(sourceHint ?? "", maxLength: 300).nilIfEmpty
        self.computedStyleSummary = computedStyleSummary.reduce(into: [:]) { acc, pair in
            let key = Self.redactedLine(pair.key, maxLength: 48)
            let value = Self.redactedLine(pair.value, maxLength: 160)
            if !key.isEmpty, !value.isEmpty {
                acc[key] = value
            }
        }
        self.areaSelection = Self.redactedLine(areaSelection ?? "", maxLength: 240).nilIfEmpty
        self.cssClasses = cssClasses
            .map { Self.redactedLine($0, maxLength: 80) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { $0 }
        self.boundingBox = boundingBox
        self.createdAt = createdAt
        self.summary = Self.summary(
            explicit: summary,
            comment: self.comment,
            selectedText: self.selectedText,
            snippet: self.snippet,
            accessibilityLabel: self.accessibilityLabel,
            selector: self.selector
        )
    }

    public var chipLabel: String {
        "Comment: \(summary)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, urlString, selector, snippet, comment, summary, annotationId
        case selectedText, nearbyText, accessibilityLabel, sourceHint
        case computedStyleSummary, areaSelection, cssClasses, boundingBox, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            urlString: try c.decodeIfPresent(String.self, forKey: .urlString),
            selector: try c.decodeIfPresent(String.self, forKey: .selector) ?? "",
            snippet: try c.decodeIfPresent(String.self, forKey: .snippet) ?? "",
            comment: try c.decodeIfPresent(String.self, forKey: .comment) ?? "",
            summary: try c.decodeIfPresent(String.self, forKey: .summary),
            annotationId: try c.decodeIfPresent(String.self, forKey: .annotationId),
            selectedText: try c.decodeIfPresent(String.self, forKey: .selectedText),
            nearbyText: try c.decodeIfPresent(String.self, forKey: .nearbyText),
            accessibilityLabel: try c.decodeIfPresent(String.self, forKey: .accessibilityLabel),
            sourceHint: try c.decodeIfPresent(String.self, forKey: .sourceHint),
            computedStyleSummary: try c.decodeIfPresent([String: String].self, forKey: .computedStyleSummary) ?? [:],
            areaSelection: try c.decodeIfPresent(String.self, forKey: .areaSelection),
            cssClasses: try c.decodeIfPresent([String].self, forKey: .cssClasses) ?? [],
            boundingBox: try c.decodeIfPresent(BoundingBox.self, forKey: .boundingBox),
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(urlString, forKey: .urlString)
        try c.encode(selector, forKey: .selector)
        try c.encode(snippet, forKey: .snippet)
        try c.encode(comment, forKey: .comment)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(annotationId, forKey: .annotationId)
        try c.encodeIfPresent(selectedText, forKey: .selectedText)
        try c.encodeIfPresent(nearbyText, forKey: .nearbyText)
        try c.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        try c.encodeIfPresent(sourceHint, forKey: .sourceHint)
        try c.encode(computedStyleSummary, forKey: .computedStyleSummary)
        try c.encodeIfPresent(areaSelection, forKey: .areaSelection)
        try c.encode(cssClasses, forKey: .cssClasses)
        try c.encodeIfPresent(boundingBox, forKey: .boundingBox)
        try c.encode(createdAt, forKey: .createdAt)
    }

    public func standardMarkdown() -> String {
        var lines: [String] = [
            "[BROWSER COMMENT]",
            "Summary: \(Self.redactedLine(summary, maxLength: 80))"
        ]
        if let urlString, !urlString.isEmpty {
            lines.append("URL: \(urlString)")
        }
        if !selector.isEmpty {
            lines.append("Selector: \(selector)")
        }
        if let accessibilityLabel, !accessibilityLabel.isEmpty {
            lines.append("Accessibility: \(accessibilityLabel)")
        }
        if let sourceHint, !sourceHint.isEmpty {
            lines.append("Source hint: \(sourceHint)")
        }
        if let areaSelection, !areaSelection.isEmpty {
            lines.append("Area selection: \(areaSelection)")
        }
        if let selectedText, !selectedText.isEmpty {
            lines.append("Selected text: \(selectedText)")
        }
        if !snippet.isEmpty {
            lines.append("Snippet: \(snippet)")
        }
        if let nearbyText, !nearbyText.isEmpty {
            lines.append("Nearby text: \(nearbyText)")
        }
        if !cssClasses.isEmpty {
            lines.append("Classes: \(cssClasses.joined(separator: " "))")
        }
        if !computedStyleSummary.isEmpty {
            let style = computedStyleSummary
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            lines.append("Computed style: \(Self.redactedLine(style, maxLength: 700))")
        }
        if let boundingBox {
            lines.append("Bounds: x=\(Int(boundingBox.x)) y=\(Int(boundingBox.y)) w=\(Int(boundingBox.width)) h=\(Int(boundingBox.height))")
        }
        lines.append("User comment:")
        lines.append(comment)
        lines.append("[/BROWSER COMMENT]")
        return lines.joined(separator: "\n")
    }

    public static func summary(
        explicit: String?,
        comment: String,
        selectedText: String?,
        snippet: String,
        accessibilityLabel: String?,
        selector: String
    ) -> String {
        let candidates = [
            explicit,
            comment,
            selectedText,
            accessibilityLabel,
            snippet,
            selector
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let source = candidates.first(where: { !$0.isEmpty }) ?? "Browser note"
        let words = source
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "Browser note" : joined
    }

    public static func redactedLine(_ raw: String, maxLength: Int) -> String {
        redactedText(raw, maxLength: maxLength)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func redactedText(_ raw: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(min(raw.unicodeScalars.count, maxLength))
        for scalar in raw.unicodeScalars {
            if out.count >= maxLength { break }
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                out.append(scalar)
            } else if (scalar.value < 0x20) || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                out.append(UnicodeScalar(0x20)!)
            } else {
                out.append(scalar)
            }
        }
        var value = String(out)
        let patterns = [
            #"(?i)(authorization|bearer|token|api[_-]?key|secret|password|cookie)\s*[=:]\s*[A-Za-z0-9._~+/=-]{6,}"#,
            #"(?i)(sessionid|csrf|xsrf)\s*[=:]\s*[A-Za-z0-9._~+/=-]{6,}"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: [.regularExpression]
            )
        }
        value = value
            .replacingOccurrences(of: "[BROWSER COMMENT]", with: "[browser comment]")
            .replacingOccurrences(of: "[/BROWSER COMMENT]", with: "[/browser comment]")
            .replacingOccurrences(of: "# Browser context", with: "# browser context")
        return value
    }
}

public struct ComposerDraftPayload: Codable, Equatable, Sendable {
    public var text: String
    public var attachmentPaths: [String]
    public var browserComments: [BrowserCommentContext]

    public init(
        text: String = "",
        attachmentPaths: [String] = [],
        browserComments: [BrowserCommentContext] = []
    ) {
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.browserComments = browserComments
    }

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachmentPaths.isEmpty
            || !browserComments.isEmpty
    }

    public func render(attachmentPaths stagedAttachmentPaths: [URL]? = nil) -> String {
        let paths = stagedAttachmentPaths?.map(\.path) ?? attachmentPaths
        var lines = paths.map { "@\($0)" }
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty {
            lines.append(prose)
        }
        if !browserComments.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("# Browser context")
            lines.append(contentsOf: browserComments.map { $0.standardMarkdown() })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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
    @Published public var customProviderId: String?
    @Published public var repoKey: String?
    @Published public var inheritedContextSourceIds: Set<UUID> = []
    @Published public private(set) var browserComments: [BrowserCommentContext] = []
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

    @discardableResult
    public func addBrowserComment(_ comment: BrowserCommentContext) -> UUID {
        browserComments.append(comment)
        return comment.id
    }

    public func removeBrowserComment(id: UUID) {
        browserComments.removeAll { $0.id == id }
    }

    public func clearBrowserComments() {
        browserComments.removeAll()
    }

    // MARK: - Compose flow control

    /// Reset the composer for the next prompt. Keeps chip state.
    public func clearAfterSend() {
        text = ""
        attachments.removeAll()
        browserComments.removeAll()
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

    public func restoreDraft(
        text: String,
        attachments: [Attachment],
        browserComments: [BrowserCommentContext] = [],
        error: SendError? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.browserComments = browserComments
        self.lastError = error
        self.isSending = false
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
        resetInheritedContext()
    }

    public func resetInheritedContext() {
        inheritedContextSourceIds.removeAll()
    }

    public struct ChipDefaults: Sendable, Equatable {
        public let agent: AgentKind
        public let modelId: String?
        public let effort: ReasoningEffort?
        public let mode: SessionMode
        public let planMode: Bool
        public init(
            agent: AgentKind = .claude,
            modelId: String? = "claude-opus-4-8-1m",
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
            let entry = catalog.entries(for: agent).first
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
    public func resetChipsForAgent(_ agent: AgentKind, catalog: ModelCatalog = .bundled) {
        let defaults = ChipDefaults.for(agent: agent, catalog: catalog)
        self.agent = agent
        self.customProviderId = nil
        self.modelId = defaults.modelId
        self.effort = defaults.effort
    }

    // MARK: - Output rendering

    /// Compose the final prompt body sent to the daemon. Prepends the
    /// `@<absolute-path>` references for each attachment (per the locked
    /// image-handling decision) and the user's text. **Includes a trailing
    /// newline** because terminal-driven submitters expect one
    /// (Codex P0 finding 2026-05-18).
    public func renderPromptBody(attachmentPaths: [URL]) -> String {
        draftPayload().render(attachmentPaths: attachmentPaths)
    }

    public func draftPayload(attachmentPaths: [String]? = nil) -> ComposerDraftPayload {
        ComposerDraftPayload(
            text: text,
            attachmentPaths: attachmentPaths ?? attachments.map(\.sourceURL.path),
            browserComments: browserComments
        )
    }

    /// True iff the composer has any content worth sending.
    public var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !browserComments.isEmpty
    }
}
