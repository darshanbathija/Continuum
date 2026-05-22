import SwiftUI
import ClawdmeterShared

/// Read-only chat renderer for the iOS Sessions tab. Fetches the parsed
/// JSONL transcript from the Mac daemon's `/transcript?path=` endpoint
/// and shows the conversation as user / assistant bubbles + collapsed
/// "Ran N commands" tool runs, matching what the Mac chat view shows.
///
/// Previously the OutsideSessionDetailView showed only a "Read-only"
/// badge + JSONL path + last write time, which carried zero of the
/// session's actual content. With the transcript endpoint in place the
/// iPhone now gets the same chat the Mac sees for both:
///   • Outside (read-only) sessions — Conductor / Cursor / Terminal
///   • Clawdmeter-spawned sessions on the structured tab
struct iOSChatTranscriptView: View {
    let jsonlPath: String
    /// Optional banner to surface above the chat — e.g. a "Read-only"
    /// pill for outside sessions plus an explanatory line.
    let banner: BannerStyle?
    @ObservedObject var client: AgentControlClient

    /// v0.5.8: Recent JSONL row + its repo. When set, tapping a tray
    /// option on an `AskUserQuestion` in this transcript triggers
    /// `continueReadOnly(...)` to promote the synthetic session and
    /// forward the answer as the seed prompt. Nil for non-outside
    /// callers — the tray then renders read-only.
    var recent: RecentSession? = nil
    var repo: AgentRepo? = nil
    /// v0.5.8: parent callback fired when a tray-driven answer promotes
    /// the session to live. Mirrors `iOSComposerBar`'s `onPromoted`.
    var onPromoted: ((UUID) -> Void)? = nil

    @State private var messages: [ChatMessage] = []
    @State private var truncated: Bool = false
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    /// Whether the user is currently watching the tail of the chat.
    /// Toggled by the per-row `.onAppear`/`.onDisappear` on the last item.
    /// When false the "Jump to latest" floating CTA appears and a reload
    /// won't auto-scroll the user out of history.
    @State private var userPinnedToBottom: Bool = true
    /// Audit P1 fix: track the deferred-scroll task so we can cancel it
    /// on disappear instead of letting a DispatchWorkItem fire against
    /// stale state.
    @State private var scrollSettleTask: Task<Void, Never>? = nil
    /// v0.5.8: per-tool_use_id selection state for AskUserQuestion
    /// trays embedded in the transcript. Persists across reloads
    /// triggered by the `.task(id: jsonlPath)` modifier.
    @State private var askUserQuestionSelections: [String: [String: Set<String>]] = [:]
    /// v0.5.8: tool_use_ids whose tray has fired an answer already
    /// (locally). Used to disable the send button until the parent
    /// promotes — there's no live tool_result on a synthetic outside
    /// session.
    @State private var answeredAsk: Set<String> = []

    enum BannerStyle {
        case readOnlyOutside
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Couldn't load transcript",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "ellipsis.bubble",
                    description: Text("The JSONL exists but doesn't contain any assistant or user messages.")
                )
            } else {
                chatList
            }
        }
        .task(id: jsonlPath) { await load() }
        .refreshable { await load() }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let banner { bannerView(banner) }
                        if truncated {
                            Label(
                                "Showing the most recent 500 messages — older history stays on your Mac.",
                                systemImage: "rectangle.compress.vertical"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                        }
                        ForEach(items) { item in
                            itemRow(item)
                                .id(item.id)
                                .padding(.horizontal, 12)
                                .onAppear {
                                    if item.id == items.last?.id {
                                        userPinnedToBottom = true
                                    }
                                }
                                .onDisappear {
                                    if item.id == items.last?.id {
                                        userPinnedToBottom = false
                                    }
                                }
                        }
                        Color.clear.frame(height: 12).id("bottom-anchor")
                    }
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .onAppear {
                    jumpToLatest(proxy, animated: false)
                    // Audit P1 fix: previous code did a 0.15s `asyncAfter`
                    // to retry the scroll after the layout settled; the
                    // deadline races against rapid state changes (filter
                    // toggles, transcript reload) and ends up scrolling
                    // against stale state. Use a SwiftUI Task that
                    // suspends instead of a queued DispatchWorkItem —
                    // cancelled automatically when the view disappears.
                    scrollSettleTask?.cancel()
                    scrollSettleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        jumpToLatest(proxy, animated: false)
                    }
                }
                .onDisappear {
                    scrollSettleTask?.cancel()
                    scrollSettleTask = nil
                }
                .onChange(of: messages.count) { _, _ in
                    guard userPinnedToBottom else { return }
                    jumpToLatest(proxy, animated: true)
                }

                if !userPinnedToBottom, !messages.isEmpty {
                    Button(action: {
                        userPinnedToBottom = true
                        jumpToLatest(proxy, animated: true)
                    }) {
                        Label("Latest", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: userPinnedToBottom)
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        let target: AnyHashable = items.last?.id ?? "bottom-anchor"
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func bannerView(_ style: BannerStyle) -> some View {
        // v0.4.5: the read-only banner is gone. Outside JSONLs are
        // continuable from the composer at the bottom of the screen, so
        // the "Read-only" badge was misleading the user. Anything we
        // need to say about provenance shows in the row subtitle / Mac
        // detail header instead.
        EmptyView()
    }

    // MARK: - Items

    /// Bucket consecutive tool_use / tool_result messages into "Ran N
    /// commands" disclosure groups, the same way the Mac
    /// `ChatThreadScroll` does. Plain prose flushes the pending run.
    private var items: [Item] {
        var out: [Item] = []
        var pending: [(call: ChatMessage, result: ChatMessage?)] = []
        var pendingIndex: [String: Int] = [:]

        func flushPending() {
            guard !pending.isEmpty else { return }
            out.append(.toolRun(id: pending.first!.call.id, pairs: pending))
            pending.removeAll()
            pendingIndex.removeAll()
        }

        for msg in messages {
            switch msg.kind {
            case .toolCall:
                let toolUseId = msg.id.hasPrefix("call:")
                    ? String(msg.id.dropFirst("call:".count)) : msg.id
                pendingIndex[toolUseId] = pending.count
                pending.append((call: msg, result: nil))
            case .toolResult:
                let toolUseId = msg.id.hasPrefix("result:")
                    ? String(msg.id.dropFirst("result:".count)) : msg.id
                if let idx = pendingIndex[toolUseId] {
                    pending[idx].result = msg
                }
            case .userText, .assistantText, .meta:
                flushPending()
                out.append(.message(msg))
            }
        }
        flushPending()
        return out
    }

    enum Item: Identifiable {
        case message(ChatMessage)
        case toolRun(id: String, pairs: [(call: ChatMessage, result: ChatMessage?)])
        var id: String {
            switch self {
            case .message(let m): return m.id
            case .toolRun(let id, _): return "run:\(id)"
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: Item) -> some View {
        switch item {
        case .message(let m):
            messageBubble(m)
        case .toolRun(_, let pairs):
            // v0.5.8: parity with the live chat thread. Partition by
            // tool kind: Edit/MultiEdit/Write → EditDiffRow chips,
            // AskUserQuestion → interactive tray, everything else →
            // existing tool-run card.
            let editPairs = pairs.filter { $0.call.editStats != nil }
            let askPairs  = pairs.filter { $0.call.askUserQuestion != nil }
            let otherPairs = pairs.filter {
                $0.call.editStats == nil && $0.call.askUserQuestion == nil
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(editPairs, id: \.call.id) { pair in
                    if let stats = pair.call.editStats {
                        EditDiffRow(stats: stats, resultBody: pair.result?.body)
                    }
                }
                ForEach(askPairs, id: \.call.id) { pair in
                    if let q = pair.call.askUserQuestion {
                        let toolUseId = pair.call.id
                        AskUserQuestionTray(
                            question: q,
                            answered: pair.result != nil || answeredAsk.contains(toolUseId),
                            selections: Binding(
                                get: { askUserQuestionSelections[toolUseId] ?? [:] },
                                set: { askUserQuestionSelections[toolUseId] = $0 }
                            )
                        ) { _, options in
                            handleAskUserQuestionAnswer(
                                toolUseId: toolUseId,
                                options: options
                            )
                        }
                    }
                }
                if !otherPairs.isEmpty {
                    toolRunCard(pairs: otherPairs)
                }
            }
        }
    }

    /// v0.5.8 outside-session answer routing. When the transcript view
    /// is rendering a Recent JSONL row (`recent` is set), tapping a
    /// tray option promotes the synthetic session via
    /// `continueReadOnly(prompt: <answer>)` — same single-shot path the
    /// composer uses for typed prompts. The matching `onPromoted`
    /// callback flips parent navigation to the new live session.
    ///
    /// When `recent` is nil (transcript view is being used outside the
    /// outside-session flow), the tap is a no-op aside from marking
    /// the tray as answered locally.
    private func handleAskUserQuestionAnswer(
        toolUseId: String,
        options: [AskUserQuestion.Option]
    ) {
        let answer = options.map(\.label).joined(separator: ", ")
        answeredAsk.insert(toolUseId)
        guard let recent, let repo else { return }
        Task {
            let newId = await client.continueReadOnly(
                jsonlPath: recent.path,
                repoKey: repo.key,
                agent: recent.provider,
                prompt: answer
            )
            if let newId {
                await client.refreshSessions()
                onPromoted?(newId)
            } else {
                // continueReadOnly failed; re-enable the tray so the
                // user can retry. We DON'T clear the selection — they
                // shouldn't have to pick again.
                await MainActor.run { answeredAsk.remove(toolUseId) }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        switch msg.kind {
        case .userText:
            HStack {
                Spacer(minLength: 40)
                Text(msg.body)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .textSelection(.enabled)
            }
        case .assistantText:
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(msg.body)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(.systemBackground),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
        case .meta:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(msg.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        case .toolCall, .toolResult:
            // Loose tool rows (no matching pair) — rare. Render as a
            // single-line system note.
            HStack(spacing: 6) {
                Image(systemName: msg.kind == .toolCall ? "wrench.fill" : "checkmark.seal")
                    .foregroundStyle(.secondary)
                Text(msg.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func toolRunCard(pairs: [(call: ChatMessage, result: ChatMessage?)]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs, id: \.call.id) { pair in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: iconFor(toolName: pair.call.title))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(pair.call.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(pair.call.body)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let detail = pair.call.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                        if let result = pair.result, !result.body.isEmpty {
                            Text(result.body)
                                .font(.caption2.monospaced())
                                .foregroundStyle(result.isError ? .red : .secondary)
                                .lineLimit(4)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func iconFor(toolName: String) -> String {
        switch toolName {
        case "Read", "Glob", "Grep": return "doc.text.magnifyingglass"
        case "Edit", "Write": return "pencil"
        case "Bash": return "terminal"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench"
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        errorMessage = nil
        guard client.host != nil, client.token != nil else {
            errorMessage = "Pair this iPhone with your Mac first (Settings → Sessions on the Mac)."
            isLoading = false
            return
        }
        let envelope = await client.fetchTranscript(path: jsonlPath)
        isLoading = false
        guard let envelope else {
            errorMessage = "Couldn't reach the Mac daemon. Make sure Clawdmeter is running on your Mac and your Tailscale connection is healthy."
            return
        }
        messages = envelope.messages
        truncated = envelope.truncated
    }
}
