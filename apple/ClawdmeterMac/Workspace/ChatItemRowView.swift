import SwiftUI
import AppKit
import ClawdmeterShared

/// A9 (Phase 2 perf) — one row of the chat transcript, extracted from
/// `ChatThreadScroll`'s inline `itemRow(_:)` helper so SwiftUI can use
/// the row's `Equatable` conformance to skip body re-evaluation when
/// the row's value props are unchanged.
///
/// **Why this exists:** A5 (PR #153) sliced `SessionChatStore` publishing
/// per-concern so `messagesSlice` only invalidates on transcript changes.
/// That stopped the composer + activity-strip from re-rendering on
/// every token tick, but the transcript's own `LazyVStack` ForEach
/// closure was still inlined inside `ChatThreadScroll.body`. Each token
/// tick → `messagesSlice.items` republishes → `ChatThreadScroll.body`
/// re-runs → the ForEach closure re-builds a view tree for every row
/// (even the historical ones whose payload is bitwise identical).
///
/// With `itemRow(_:)` being a function returning `some View`, the
/// closure body executes per parent invalidation. SwiftUI's diffing
/// merges identical sub-trees behind the scenes, but the closure
/// itself ran, calling `presentationStore.snapshot.messageBookmarks[…]`,
/// allocating the rendering view tree, and yielding garbage. With the
/// row extracted to a struct view conforming to `Equatable`, SwiftUI
/// short-circuits at the equality check and never calls `.body` on
/// historical rows whose payload didn't move.
///
/// **The streaming bubble** still re-renders every token. We give it
/// its own wrapper (`StreamingMessageView`) that taps the
/// `BodyInvalidationCounter` under a distinct label so the per-token
/// invalidation cost is measurable + assertable in tests. The wrapper
/// delegates rendering to the same `ChatItemRowContent` helper used by
/// the historical row so visual parity is structural.
///
/// **Plan:** A9 (Phase 2). Acceptance per
/// `.claude/plans/study-this-codebase-crystalline-shore.md`: only the
/// streaming bubble re-renders during a burst; historical rows stay
/// flat. Verified by `ChatItemRowInvalidationTests` against the A0
/// `messages10k` fixture.

// MARK: - Value-typed payload

/// All inputs that affect the visual output of a single chat row, in a
/// form `ChatItemRowView` can compare cheaply via `==`. Stored as one
/// nested value so the row view's manual `Equatable` impl reads as a
/// single member compare instead of a long property chain.
///
/// **Compared members carry visual meaning:** any change in this
/// struct should produce a visible change in the row. Anything that
/// doesn't (closures, observed objects we don't read fields of) lives
/// outside the payload — see `ChatItemRowActions`.
struct ChatItemRowPayload: Equatable {
    /// The item to render. Hashable + Equatable per the
    /// `ChatItem` enum's auto-synthesis.
    let item: ChatItem
    /// Row insets + font sizing derived from the workspace's density
    /// setting. Compact / balanced / detailed map to distinct visual
    /// presentations; included so density changes invalidate the row.
    let density: TranscriptDensity
    /// Whether the user has bookmarked this message id (only meaningful
    /// for `.message` items). Computed once by the parent so the row
    /// doesn't need an `ObservedObject` reference to `presentationStore`.
    let isBookmarked: Bool
    /// Find-bar highlight state. `.none` for non-matches, `.match` for
    /// matched bodies, `.selectedMatch` for the currently navigated one.
    let highlight: HighlightState
    /// Provider glyph (Claude / Codex / Antigravity / OpenCode / Cursor).
    /// Stable for a given session; included so a mode-switch repaints
    /// the assistant bubbles immediately.
    let providerGlyph: TahoeProvider
    /// Repo root used to resolve transcript path links. `nil` for
    /// synthetic / read-only Recent JSONL rows where no cwd is set.
    let repoRoot: URL?
    /// Markdown syntax theme — affects assistant bubble fenced code
    /// rendering. Pulled from `SessionPresentationStore.snapshot`.
    let syntaxTheme: CodeSyntaxTheme
    /// For `.toolRun` items: whether the "Ran N commands" disclosure
    /// is currently expanded. The parent owns the `expanded` set and
    /// projects this single bool per row so the comparison stays
    /// cheap and per-row-targeted.
    let isToolRunOpen: Bool
    /// Per-pair expansion within this row's tool run. Keyed by
    /// `pair.id` (tool_use_id). Empty for `.message` rows.
    let toolPairsOpen: [String: Bool]
    /// Per-pair AskUserQuestion selection state. Keyed by
    /// `pair.id`. Mutates rarely — only when the user taps an
    /// option — so a streaming burst leaves this untouched and the
    /// row's `==` stays true.
    let askSelections: [String: [String: Set<String>]]
    /// Whether THIS row is the actively-streaming tail. Drives the
    /// `BodyInvalidationCounter` label so streaming and historical
    /// invalidations are counted separately, AND triggers the
    /// `StreamingMessageView` wrapper to flip back to a plain
    /// `ChatItemRowView` at turn boundary (when the same item id
    /// transitions from streaming to committed).
    let isStreamingTail: Bool

    /// Markdown find-bar highlight projection. Three discrete states
    /// so the row's `Equatable` doesn't have to compare the full match
    /// array per render.
    enum HighlightState: Equatable, Hashable {
        case none
        case match
        case selectedMatch
    }
}

// MARK: - Closure surface

/// Closures the row fires to mutate parent state (toggle disclosures,
/// answer AskUserQuestion, copy / bookmark / quote-reply messages).
/// Held outside `ChatItemRowPayload` because closures aren't
/// `Equatable`; they'd defeat the row's `==` shortcut.
///
/// Closures are captured by the parent's `View` value — they hold
/// references to `@State` / `@ObservedObject` / `Binding` setters
/// that survive across body re-evals. As long as the parent's state
/// doesn't change (which it won't during a streaming burst), the
/// closure values stay reference-stable.
struct ChatItemRowActions {
    /// Toggle the "Ran N commands" disclosure for a tool run.
    let onToggleToolRun: (_ runId: String, _ shouldOpen: Bool) -> Void
    /// Toggle a single tool pair's disclosure within a tool run.
    let onToggleToolPair: (_ pairId: String, _ shouldOpen: Bool) -> Void
    /// Apply a new AskUserQuestion selection state for a pair id.
    let onUpdateAskSelections: (_ pairId: String, _ selections: [String: Set<String>]) -> Void
    /// Fire-and-forget answer send to the session's tmux pane.
    let onAnswerAsk: (_ answer: String) -> Void
    /// Copy text to the system pasteboard.
    let onCopy: (_ text: String) -> Void
    /// Open the composer with a `> `-quoted version of the message.
    let onQuoteReply: (_ body: String) -> Void
    /// Toggle the bookmark on a message id.
    let onToggleBookmark: (_ messageId: String) -> Void
    /// Open a generated Markdown document in the Code workspace tab strip.
    let onOpenMarkdownDocument: (_ path: String) -> Void
}

// MARK: - Equatable row view (historical rows)

/// One row of the chat transcript. SwiftUI's diffing skips `body`
/// when this view's payload is `==` to the prior render — which is
/// the whole point of A9: a streaming token tick re-publishes
/// `messagesSlice.items` (the whole array) but the historical rows'
/// payloads are unchanged, so their bodies don't run.
///
/// **Counter label:** `"ChatItemRowView"`. Used by
/// `ChatItemRowInvalidationTests` to assert the per-burst
/// invalidation count for historical rows stays flat.
struct ChatItemRowView: View, Equatable {
    let payload: ChatItemRowPayload
    let actions: ChatItemRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Only the payload is compared. Closures in `actions` are
        // reference-stable across the parent's lifetime (they
        // capture `@State` setters whose addresses don't move).
        // Comparing them would fail trivially and re-enable the body.
        lhs.payload == rhs.payload
    }

    var body: some View {
        // A9: instrument body invalidations. No-op in production
        // because `BodyInvalidationCounter.enabled` defaults to
        // false. Tests flip it on, drive the streaming burst, and
        // assert this counter stays flat.
        let _ = BodyInvalidationCounter.bump("ChatItemRowView")
        return ChatItemRowContent(payload: payload, actions: actions)
    }
}

// MARK: - Streaming bubble wrapper

/// The actively-streaming chat row. Visually identical to a
/// historical `ChatItemRowView` — same content view underneath —
/// but tagged with its own `BodyInvalidationCounter` label so the
/// per-token-tick body re-eval cost is measurable separately from
/// the historical rows.
///
/// **NOT Equatable.** The whole point of this view is that it
/// re-renders every token. The parent constructs a new instance per
/// `messagesSlice.items` publish with a fresh `item.body` string;
/// SwiftUI sees the value moved and runs `body`.
///
/// **Counter label:** `"StreamingMessageView"`. Used by
/// `ChatItemRowInvalidationTests` to assert the streaming bubble's
/// body runs roughly once per token in a burst.
struct StreamingMessageView: View {
    let payload: ChatItemRowPayload
    let actions: ChatItemRowActions

    var body: some View {
        // A9: streaming-only counter. Distinct label so the test can
        // separate "100 ticks → 100 streaming-body invalidations"
        // from the "historical-row body should stay flat" assertion.
        let _ = BodyInvalidationCounter.bump("StreamingMessageView")
        return ChatItemRowContent(payload: payload, actions: actions)
    }
}

// MARK: - Shared rendering content

/// The actual rendering. Both `ChatItemRowView` (historical) and
/// `StreamingMessageView` (live streaming) delegate here so the
/// visual presentation is identical regardless of which counter
/// label is tapped.
///
/// Internal to the Mac target. The two outer wrappers are the
/// public-ish surface; consumers in `ChatThreadScroll` build them
/// via small helper functions on the parent.
struct ChatItemRowContent: View {
    let payload: ChatItemRowPayload
    let actions: ChatItemRowActions

    @Environment(\.tahoe) private var t

    var body: some View {
        switch payload.item {
        case .message(let m):
            messageRow(m)
        case .toolRun(let runId, let pairs):
            toolRunBody(runId: runId, pairs: pairs)
        }
    }

    // MARK: Tool-run row

    /// v0.5.5/v0.5.6: partition the tool-run pairs by tool kind:
    ///   • Edit/MultiEdit/Write → inline EditDiffRow chips
    ///   • AskUserQuestion       → interactive AskUserQuestionTray
    ///   • everything else       → "Ran N commands" disclosure
    ///
    /// v0.29.4: the "everything else" bucket previously rendered each
    /// tool pair as its own row, which meant a long agent burst (50
    /// sed/rg/cat probes) flooded the transcript. Wrap them in a
    /// single `toolRunGroup` collapsed pill.
    @ViewBuilder
    private func toolRunBody(runId: String, pairs: [ToolPair]) -> some View {
        let editPairs = pairs.filter { $0.call.editStats != nil }
        let askPairs  = pairs.filter { $0.call.askUserQuestion != nil }
        let otherPairs = pairs.filter {
            $0.call.editStats == nil && $0.call.askUserQuestion == nil
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editPairs) { pair in
                if let stats = pair.call.editStats {
                    EditDiffRow(
                        stats: stats,
                        editDiff: pair.call.editDiff,
                        resultBody: pair.result?.body,
                        density: payload.density
                    )
                }
            }
            ForEach(askPairs) { pair in
                if let q = pair.call.askUserQuestion {
                    AskUserQuestionTray(
                        question: q,
                        answered: pair.result != nil,
                        selections: Binding(
                            get: { payload.askSelections[pair.id] ?? [:] },
                            set: { actions.onUpdateAskSelections(pair.id, $0) }
                        )
                    ) { _, options in
                        let answer = options.map(\.label).joined(separator: ", ")
                        actions.onAnswerAsk(answer)
                    }
                }
            }
            ForEach(markdownArtifacts(in: pairs)) { artifact in
                generatedArtifactButton(artifact)
            }
            if !otherPairs.isEmpty {
                toolRunGroup(id: runId, pairs: otherPairs)
            }
        }
    }

    private func markdownArtifacts(in pairs: [ToolPair]) -> [GeneratedArtifact] {
        var seen: Set<String> = []
        var out: [GeneratedArtifact] = []
        for artifact in pairs.flatMap({ $0.call.generatedArtifacts }) where artifact.kind == .markdownDocument {
            guard !seen.contains(artifact.path) else { continue }
            seen.insert(artifact.path)
            out.append(artifact)
        }
        return out
    }

    private func generatedArtifactButton(_ artifact: GeneratedArtifact) -> some View {
        Button {
            actions.onOpenMarkdownDocument(artifact.path)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.accent)
                Text((artifact.path as NSString).lastPathComponent.isEmpty ? artifact.path : (artifact.path as NSString).lastPathComponent)
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(t.hair2, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open Markdown document in Code tab")
    }

    @ViewBuilder
    private func messageRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        Group {
            switch msg.kind {
            case .userText:      userBubble(msg)
            case .assistantText: assistantBubble(msg)
            case .toolCall, .toolResult:
                // Should never hit: tool messages are folded into ChatItem.toolRun.
                EmptyView()
            case .meta:          metaRow(msg)
            }
        }
        .id(msg.id)
        .background(highlightColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            if payload.isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .padding(.leading, 2)
                    .padding(.top, 1)
                    .help("Bookmarked")
            }
        }
        .contextMenu {
            messageActions(msg)
        }
    }

    private var highlightColor: Color {
        switch payload.highlight {
        case .none: return .clear
        case .selectedMatch: return t.accentAlpha(0.18)
        case .match: return SessionsV2Theme.warn.opacity(t.dark ? 0.16 : 0.22)
        }
    }

    @ViewBuilder
    private func messageActions(_ msg: SessionChatStore.ChatMessage) -> some View {
        Button("Copy Message", systemImage: "doc.on.doc") {
            actions.onCopy(msg.body)
        }
        Button("Quote Reply", systemImage: "quote.bubble") {
            actions.onQuoteReply(msg.body)
        }
        Button(payload.isBookmarked ? "Remove Bookmark" : "Bookmark",
               systemImage: payload.isBookmarked ? "bookmark.slash" : "bookmark") {
            actions.onToggleBookmark(msg.id)
        }
        Button("Copy Message ID", systemImage: "number") {
            actions.onCopy(msg.id)
        }
    }

    private func userBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 4) {
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(ClawdmeterMac_displaySkillInvocations(in: msg.body))
                        .font(TahoeFont.body(bodyFontSize))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 640, alignment: .trailing)
            }
        }
    }

    private func assistantBubble(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TahoeProviderGlyph(provider: payload.providerGlyph, size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                MarkdownRenderer(source: msg.body, syntaxTheme: payload.syntaxTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pathLinkStripIfAny(body: msg.body)
            }
            Spacer(minLength: 64)
        }
    }

    /// v0.29.x: the path-link strip needs a `presentationStore` to
    /// resolve clicks. Since the row is now isolated from that store
    /// (so it can be Equatable), we surface the strip only when the
    /// parent supplied a repoRoot — without the store, clicks would
    /// be no-ops. The strip itself is owned by `TranscriptPathLinks.swift`
    /// and reads the store from the SwiftUI environment when present.
    @ViewBuilder
    private func pathLinkStripIfAny(body: String) -> some View {
        if let root = payload.repoRoot {
            let links = Array(ResolvablePathLinkParser.links(in: body, repoRoot: root).prefix(8))
            if !links.isEmpty {
                TranscriptPathLinkStripWithEnvironment(
                    links: links,
                    onOpenMarkdownDocument: actions.onOpenMarkdownDocument
                )
            }
        }
    }

    private func metaRow(_ msg: SessionChatStore.ChatMessage) -> some View {
        HStack {
            Spacer()
            Text(msg.body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Tool-run / pair rendering

    private func toolRunGroup(id: String, pairs: [ToolPair]) -> some View {
        let isOpen = Binding<Bool>(
            get: { payload.isToolRunOpen },
            set: { actions.onToggleToolRun(id, $0) }
        )
        // The most recent pair without a result is the in-flight step.
        // While present, render a subtitle next to the chip; once all
        // pairs have results the subtitle dissolves.
        let runningStep: ToolPair? = pairs.last(where: { $0.result == nil })
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs) { pair in
                    toolPairRow(pair)
                }
            }
            .padding(.leading, 16)
            .padding(.top, 4)
        } label: {
            // v0.29.26: subtitle moves inline next to the "Ran N commands"
            // pill instead of stacking underneath. Outer HStack keeps the
            // pill (background-capsuled) and the running subtitle on the
            // same baseline; the subtitle truncates with ellipsis when
            // the row narrows.
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 6) {
                    TahoeIcon("terminal", size: 10)
                        .foregroundStyle(t.fg3)
                    HStack(spacing: 0) {
                        Text("Ran ")
                        Text("\(pairs.count)")
                            .monospacedDigit()
                            .frame(width: 20, alignment: .trailing)
                            .contentTransition(.numericText(value: Double(pairs.count)))
                            .animation(.easeOut(duration: 0.10), value: pairs.count)
                        Text(" command")
                        Text("s")
                            .opacity(pairs.count == 1 ? 0 : 1)
                            .transaction { $0.animation = nil }
                    }
                    .font(TahoeFont.body(11.5, weight: .semibold))
                    .foregroundStyle(t.fg2)
                    .accessibilityLabel(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    ZStack {
                        if runningStep != nil {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                        }
                    }
                    .frame(width: 12, height: 12)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(t.hair2, in: Capsule(style: .continuous))

                if let running = runningStep {
                    Text("· \(runningStepSubtitle(running))")
                        .font(TahoeFont.body(10))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(QuietDisclosure())
        .animation(.easeInOut(duration: 0.22), value: runningStep?.id)
    }

    /// One-liner shown under the "Ran N commands" pill while a tool call
    /// is in flight. Delegates to the module-scope
    /// `runningStepSubtitle(forTool:body:)` pure helper so the
    /// string-transform is unit-testable without a SwiftUI host.
    private func runningStepSubtitle(_ pair: ToolPair) -> String {
        ClawdmeterMac_runningStepSubtitle(forTool: pair.call.title, body: pair.call.body)
    }

    private func toolPairRow(_ pair: ToolPair) -> some View {
        let isOpen = Binding<Bool>(
            get: { payload.toolPairsOpen[pair.id] ?? false },
            set: { actions.onToggleToolPair(pair.id, $0) }
        )
        let isError = pair.result?.isError ?? false
        let bashResult = pair.result?.bashResult ?? pair.call.bashResult
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let bashResult {
                    bashResultView(bashResult, isError: isError)
                } else if let detail = pair.call.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                if let result = pair.result,
                   !result.body.isEmpty,
                   bashResult == nil || (bashResult?.stdout == nil && bashResult?.stderr == nil) {
                    Text(result.body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isError ? AnyShapeStyle(SessionsV2Theme.danger) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .lineLimit(toolOutputLineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6))
                } else if pair.result == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for result…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(pair.call.title))
                    .font(.system(size: 10))
                    .foregroundStyle(toolTint(pair.call.title))
                Text(pair.call.title)
                    .font(TahoeFont.mono(11, weight: .semibold))
                    .foregroundStyle(toolTint(pair.call.title))
                Text(pair.call.body)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(t.hair2, in: Capsule(style: .continuous))
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(QuietDisclosure())
    }

    @ViewBuilder
    private func bashResultView(_ bash: BashResult, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let command = bash.command, !command.isEmpty {
                    Label(command, systemImage: "terminal")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let exitCode = bash.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                }
                if let durationMS = bash.durationMS {
                    Text("\(durationMS) ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let cwd = bash.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let stdout = bash.stdout, !stdout.isEmpty {
                monoBlock(title: "stdout", text: stdout, tint: .secondary)
            }
            if let stderr = bash.stderr, !stderr.isEmpty {
                monoBlock(title: "stderr", text: stderr, tint: .red)
            }
            if bash.isTruncated {
                Text("Output truncated")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if bash.stdout == nil, bash.stderr == nil, bash.exitCode == nil {
                Text("Waiting for result...")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background((isError ? Color.red : t.hair2).opacity(isError ? 0.08 : 0.85),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func monoBlock(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(toolOutputLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Derived density values

    private var bodyFontSize: CGFloat {
        switch payload.density {
        case .compact: return 12
        case .balanced: return 13
        case .detailed: return 14
        }
    }

    private var toolOutputLineLimit: Int? {
        switch payload.density {
        case .compact: return 16
        case .balanced: return 40
        case .detailed: return nil
        }
    }

    private func toolIcon(_ name: String) -> String {
        ToolPresentationCatalog.presentation(for: name).systemImageName
    }

    private func toolTint(_ name: String) -> Color {
        // Generic-tool tints. Avoid the AI-slop purple — `.web` is just a
        // network fetch, not a provider identity. Route through the Codex
        // blue token so the palette stays consistent with the rest of the
        // app's tool chrome.
        switch ToolPresentationCatalog.presentation(for: name).tone {
        case .read: return SessionsV2Theme.codexBlue
        case .write: return terraCotta
        case .shell: return SessionsV2Theme.success
        case .web: return SessionsV2Theme.codexBlue
        case .agent: return SessionsV2Theme.warn
        case .warning: return SessionsV2Theme.danger
        case .neutral: return .secondary
        }
    }

    private var terraCotta: Color { SessionsV2Theme.accent }
}

// MARK: - Path-link strip shim

/// Tiny shim that pulls `SessionPresentationStore` from the
/// SwiftUI environment so `TranscriptPathLinkStrip` (which wants
/// the store as a regular property) keeps working without the
/// row holding an `@ObservedObject` reference to the store.
///
/// `SessionPresentationStore` is supplied by `ChatThreadScroll`
/// (and downstream `SessionWorkspaceView`) into the SwiftUI
/// environment. The row reads it lazily — observing it would
/// re-render the row on unrelated presentation changes, which is
/// exactly what A9 wants to avoid.
private struct TranscriptPathLinkStripWithEnvironment: View {
    let links: [ResolvablePathLink]
    let onOpenMarkdownDocument: (String) -> Void
    @Environment(\.sessionPresentationStore) private var presentationStore

    var body: some View {
        if let presentationStore {
            TranscriptPathLinkStrip(
                links: links,
                presentationStore: presentationStore,
                onOpenMarkdownDocument: onOpenMarkdownDocument
            )
        }
    }
}

// MARK: - Environment plumbing for the path-link store

private struct SessionPresentationStoreKey: EnvironmentKey {
    static let defaultValue: SessionPresentationStore? = nil
}

extension EnvironmentValues {
    /// `SessionPresentationStore` reachable from the chat row without
    /// the row taking a strong `@ObservedObject` reference. Injected
    /// by `ChatThreadScroll`; nil when the row is rendered outside the
    /// workspace (tests, previews).
    var sessionPresentationStore: SessionPresentationStore? {
        get { self[SessionPresentationStoreKey.self] }
        set { self[SessionPresentationStoreKey.self] = newValue }
    }
}

/// Pure string helper for the "Running <tool> · <input>" subtitle under
/// the Ran-N-commands disclosure. Module-scope rather than nested on
/// `ChatItemRowView` so it can be unit-tested without a SwiftUI host —
/// nested statics on a `View`-conforming struct hit
/// MainActor-isolation gotchas across `@testable` boundaries.
/// Prefixed `ClawdmeterMac_` to keep the symbol namespaced.
func ClawdmeterMac_runningStepSubtitle(forTool toolTitle: String, body: String) -> String {
    let title = toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let bodyOneLine = body
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if bodyOneLine.isEmpty || bodyOneLine == title {
        return "Running \(title)…"
    }
    let snippet = bodyOneLine.count > 60 ? String(bodyOneLine.prefix(60)) + "…" : bodyOneLine
    return "Running \(title) · \(snippet)"
}

/// Display-only cleanup for Claude Code skill invocation markers.
///
/// Claude persists a called skill as Markdown-ish text:
/// `[review](/Users/.../review/SKILL.md)`. In the Code tab that reads like
/// leaked implementation detail. The prompt/transcript body stays unchanged;
/// views call this helper only for the visible label.
func ClawdmeterMac_displaySkillInvocations(in text: String) -> String {
    let pattern = #"\[([^\]\n]+)\]\(([^)\n]*SKILL\.md)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return text
    }

    var result = text
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let matches = regex.matches(in: text, range: fullRange)

    for match in matches.reversed() {
        guard match.numberOfRanges >= 3,
              let replacementRange = Range(match.range(at: 0), in: result),
              let skillRange = Range(match.range(at: 1), in: text)
        else { continue }

        let rawName = String(text[skillRange])
        result.replaceSubrange(replacementRange, with: "Skill: \(ClawdmeterMac_skillDisplayName(rawName))")
    }

    return result
}

private func ClawdmeterMac_skillDisplayName(_ raw: String) -> String {
    let pieces = raw
        .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        .map(String.init)

    guard !pieces.isEmpty else { return "Skill" }

    return pieces
        .map { piece in
            if piece.count <= 3 {
                return piece.uppercased()
            }
            return piece.prefix(1).uppercased() + piece.dropFirst().lowercased()
        }
        .joined(separator: " ")
}
