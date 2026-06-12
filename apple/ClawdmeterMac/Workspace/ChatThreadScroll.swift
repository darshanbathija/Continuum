import SwiftUI
import AppKit
import ClawdmeterShared

struct ChatThreadScroll: View {
    // A5 — `store` is held as a plain `let` (no observation). Body
    // invalidations come from the per-concern slices below, which
    // publish only on changes to their own concern. The transcript
    // ForEach binds to `messagesSlice`; the activity indicator + the
    // load-earlier button bind to `liveStatusSlice`. Token deltas land
    // on `composerSlice` and do NOT invalidate this view's body.
    let store: SessionChatStore
    @ObservedObject var messagesSlice: ChatMessagesSlice
    @ObservedObject var liveStatusSlice: ChatLiveStatusSlice
    let session: AgentSession
    let model: SessionsModel
    @ObservedObject var presentationStore: SessionPresentationStore
    let density: TranscriptDensity
    let showPlanHalo: Bool
    let canApprovePlan: Bool
    /// v0.29.25: track the right-pane visibility so a toggle can re-anchor
    /// the scroll view to the bottom sentinel. The chat list's
    /// `userPinnedToBottom` state survives the width change, but the
    /// scroll position itself doesn't — the LazyVStack relays out at the
    /// new width, item heights shift, and the absolute content offset
    /// the scroll view kept now points mid-history.
    let isReviewPaneVisible: Bool
    let isReadOnly: Bool
    let onPlanRefine: () -> Void
    let onPlanApprove: () -> Void
    let onPreviewTurn: () -> Void
    let onRetryFailedTurn: (_ promptBody: String) -> Void
    let onRetryFailedTurnInNewChat: (_ promptBody: String) -> Void
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: SessionChatStore,
        session: AgentSession,
        model: SessionsModel,
        presentationStore: SessionPresentationStore,
        density: TranscriptDensity,
        showPlanHalo: Bool,
        canApprovePlan: Bool,
        isReviewPaneVisible: Bool,
        isReadOnly: Bool,
        onPlanRefine: @escaping () -> Void,
        onPlanApprove: @escaping () -> Void,
        onPreviewTurn: @escaping () -> Void = {},
        onRetryFailedTurn: @escaping (_ promptBody: String) -> Void = { _ in },
        onRetryFailedTurnInNewChat: @escaping (_ promptBody: String) -> Void = { _ in }
    ) {
        self.store = store
        _messagesSlice = ObservedObject(wrappedValue: store.messagesSlice)
        _liveStatusSlice = ObservedObject(wrappedValue: store.liveStatusSlice)
        self.session = session
        self.model = model
        self.presentationStore = presentationStore
        self.density = density
        self.showPlanHalo = showPlanHalo
        self.canApprovePlan = canApprovePlan
        self.isReviewPaneVisible = isReviewPaneVisible
        self.isReadOnly = isReadOnly
        self.onPlanRefine = onPlanRefine
        self.onPlanApprove = onPlanApprove
        self.onPreviewTurn = onPreviewTurn
        self.onRetryFailedTurn = onRetryFailedTurn
        self.onRetryFailedTurnInNewChat = onRetryFailedTurnInNewChat
    }

    /// IDs of expanded disclosure groups. Per-row `@State` would be ideal
    /// (A5 codex finding) but with LazyVStack recycling that loses state
    /// across scroll; this set is the simplest path that survives recycling.
    /// Tests confirm tapping one row only invalidates that row when reads
    /// flow through `messagesSlice.items` (T5).
    @State private var expanded: Set<String> = []
    /// v0.5.6: per-tool_use_id selection state for AskUserQuestion trays.
    /// `[toolUseId: [questionHeader: Set<optionLabel>]]`. Lives at the
    /// scroll-view level so picks survive list recycling during
    /// streaming bumps.
    @State private var askUserQuestionSelections: [String: [String: Set<String>]] = [:]
    @State private var showingFindBar = false
    @State private var findQuery = ""
    @State private var selectedMatchIndex: Int?
    @State private var projectionCache = SingleSlotProjectionCache<TranscriptProjectionCacheKey, TranscriptProjection>()
    // Caches the find-bar scan keyed on (query, transcript cursor). The
    // find result was previously a plain computed var recomputed up to
    // 3× per body render PLUS once per visible message row (highlightState),
    // i.e. O(rows × messages). Now a single full O(messages) scan per
    // query/transcript change feeds every reader, with an id Set for O(1)
    // per-row membership.
    @State private var findMatchCache = SingleSlotProjectionCache<FindMatchKey, FindMatchResult>()
    @FocusState private var findFocused: Bool

    var body: some View {
        // A9: tap the body-invalidation counter so the per-burst
        // measurement test can assert "ChatThreadScroll re-renders
        // ONCE per token tick" (the price of binding to
        // `messagesSlice.items`) but the historical row views — now
        // extracted to `ChatItemRowView` with Equatable conformance —
        // stay flat across the burst. No-op when
        // `BodyInvalidationCounter.enabled` is false (production).
        let _ = BodyInvalidationCounter.bump("ChatThreadScroll")
        let streamingTailId = streamingTailItemId
        let projection = transcriptProjection
        let showEmptyState = projection.turns.isEmpty && !liveStatusSlice.isLoading
        let showCenteredEmpty = showEmptyState && !liveStatusSlice.hasOlderHistory
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if liveStatusSlice.hasOlderHistory {
                            loadEarlierButton
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        if showEmptyState && liveStatusSlice.hasOlderHistory {
                            TranscriptEmptyState(style: .inline)
                                .frame(maxWidth: .infinity, alignment: .top)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !showEmptyState {
                            ForEach(projection.turns) { turn in
                                collapsedTurnView(turn, streamingTailId: streamingTailId)
                                    .id(turn.id)
                                    .padding(rowInsets)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // P4: a newly-arrived turn fades + rises in
                                    // (Codex/Claude-smooth). Fires only on turn
                                    // INSERTION — streaming tokens mutate an
                                    // existing turn.id, so this never animates
                                    // per-token and the Equatable row path is
                                    // untouched.
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        if showPlanHalo {
                            InlinePlanHalo(
                                session: session,
                                onRefine: onPlanRefine,
                                onApprove: onPlanApprove,
                                canApprove: canApprovePlan
                            )
                            .padding(rowInsets)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            LiveSessionActivityIndicator(
                                agent: session.agent,
                                lastEventAt: liveStatusSlice.lastEventAt,
                                // v0.29.4: anchor the elapsed counter to
                                // the most recent user prompt so the
                                // pill shows "how long has the model been
                                // working on this task", not "how long
                                // since I clicked into the session".
                                activityStartedAt: liveStatusSlice.currentTurnStartedAt
                            )
                            Spacer()
                        }
                        .padding(rowInsets)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomSentinelId)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Drives the P4 turn-entrance transition — keyed on the
                    // turn COUNT so it fires on insert, not on per-token content
                    // updates to the streaming tail.
                    .animation(SessionsV2Theme.disclosureToggle(reduceMotion: reduceMotion),
                               value: projection.turns.count)
                }
                .coordinateSpace(name: "transcriptScroll")
                .onPreferenceChange(TranscriptMessagePositionKey.self) { positions in
                    measuredMessagePositions.merge(positions) { _, new in new }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, height in
                    if height > 0 {
                        scrollContentHeight = height
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                    return visibleBottom >= geometry.contentSize.height - 120
                } action: { _, isAtBottom in
                    if isAtBottom || Date() < suppressBottomGeometryUntil {
                        userPinnedToBottom = true
                    } else {
                        userPinnedToBottom = false
                    }
                }
                .onChange(of: messagesSlice.updateCounter) { _, counter in
                    measuredMessagePositions = [:]
                    stickToBottomIfPinned(proxy, updateCounter: counter)
                }
                .onChange(of: isReviewPaneVisible) { _, _ in
                    // v0.29.25: width change relays the LazyVStack at a
                    // different per-row height (text wraps differently),
                    // so the absolute content offset that was bottom-
                    // anchored now lands mid-history. Re-pin only when
                    // the user was already at the bottom; respect the
                    // jump-to-latest CTA otherwise.
                    guard userPinnedToBottom else { return }
                    autoScrollTask?.cancel()
                    autoScrollTask = Task { @MainActor in
                        // One yield lets SwiftUI commit the new layout
                        // before we ask the proxy to scroll, otherwise
                        // we measure pre-resize geometry.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        await jumpToBottom(proxy, animated: false)
                    }
                }
                .onAppear {
                    userPinnedToBottom = true
                    lastScrollItemCount = messagesSlice.items.count
                    autoScrollTask?.cancel()
                    autoScrollTask = Task { @MainActor in
                        await jumpToBottom(proxy, animated: false)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled else { return }
                        await jumpToBottom(proxy, animated: false)
                    }
                }
                .onDisappear {
                    autoScrollTask?.cancel()
                    autoScrollTask = nil
                    userPinnedToBottom = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptFind)) { _ in
                    showingFindBar = true
                    findFocused = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptNextMatch)) { _ in
                    jumpToFindMatch(proxy, delta: 1)
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptPreviousMatch)) { _ in
                    jumpToFindMatch(proxy, delta: -1)
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptLatest)) { _ in
                    Task { @MainActor in await jumpToBottom(proxy, animated: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .transcriptLastUser)) { _ in
                    jumpToLastUserMessage(proxy)
                }

                if showCenteredEmpty {
                    TranscriptEmptyState()
                        .allowsHitTesting(false)
                }

                if showingFindBar {
                    VStack {
                        transcriptFindBar(proxy)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Jump-to-latest CTA. Visible whenever the user has
                // scrolled away from the bottom (a new turn lands while
                // they're reading history). Click → scroll-to-last-item.
                if !userPinnedToBottom, !projection.turns.isEmpty {
                    Button(action: {
                        autoScrollTask?.cancel()
                        autoScrollTask = Task { @MainActor in
                            await jumpToBottom(proxy, animated: true)
                        }
                    }) {
                        Label(
                            unreadWhileReading > 0 ? "Jump to latest (\(unreadWhileReading))" : "Jump to latest",
                            systemImage: "arrow.down.circle.fill"
                        )
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(ContinuumTokens.surface2, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .help("Jump to latest message (⌘↓)")
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                // v0.7.16: thinking-indicator overlay removed. It's now
                // a footer row inside the transcript flow above.

                if !projection.turns.isEmpty {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        TranscriptMessageGutter(
                            markers: TranscriptGutterPreview.markers(
                                turns: projection.turns,
                                measuredPositions: measuredMessagePositions,
                                contentHeight: scrollContentHeight
                            ),
                            onSelect: { messageId in
                                jumpToMessage(proxy, messageId: messageId)
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.top, showingFindBar ? 48 : 8)
                    .padding(.bottom, userPinnedToBottom ? 8 : 52)
                    .allowsHitTesting(true)
                }
            }
        }
        // A9: bridge `presentationStore` into the SwiftUI environment so
        // the extracted `ChatItemRowView` can resolve path-link clicks
        // without holding an `@ObservedObject` reference to the store.
        // The row needs the store only on user action (tap), not on
        // every body — pulling it through the environment lets the row
        // stay Equatable on its value payload.
        .environment(\.sessionPresentationStore, presentationStore)
    }

    /// Stable sentinel id used by ScrollViewReader to scroll to the tail.
    /// Held as a static so the id reference doesn't recompute per-render.
    private static let bottomSentinelId = "mac-chat-bottom-sentinel"

    /// Tracks whether the user is reading the tail (last item visible).
    /// When false, auto-scroll stops yanking on new turns and the "Jump
    /// to latest" button surfaces. Updated by the per-row appear/disappear.
    @State private var userPinnedToBottom: Bool = true

    @State private var lastScrollItemCount: Int = 0
    @State private var unreadWhileReading: Int = 0
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var isLoadingEarlierHistory: Bool = false
    @State private var suppressBottomGeometryUntil: Date = .distantPast
    @State private var measuredMessagePositions: [String: CGFloat] = [:]
    @State private var scrollContentHeight: CGFloat = 1

    private var transcriptProjection: TranscriptProjection {
        projectionCache.value(
            for: TranscriptProjectionCacheKey(
                updateCounter: messagesSlice.updateCounter,
                mode: .latestAnswerOnly
            )
        ) {
            TranscriptTurnProjector.project(
                items: messagesSlice.items,
                messages: messagesSlice.messages,
                mode: .latestAnswerOnly
            )
        }
    }

    private var rowInsets: EdgeInsets {
        switch density {
        case .compact:
            return EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14)
        case .balanced:
            return EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
        case .detailed:
            return EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        }
    }

    // A9: per-row `bodyFontSize` + `toolOutputLineLimit` now live in
    // `ChatItemRowContent` (in `ChatItemRowView.swift`) — derived from
    // the passed-in density. Kept out of ChatThreadScroll so the row
    // doesn't need a reference back to the parent.

    /// Cache key for the find scan: the trimmed query + the transcript
    /// cursor. A stable (query, cursor) pair is a cache hit, so the scan
    /// runs once even though several readers ask for it within one render.
    private struct FindMatchKey: Equatable {
        let query: String
        let updateCounter: UInt64
    }

    private struct FindMatchResult {
        let matches: [SessionChatStore.ChatMessage]
        let matchedIds: Set<String>
    }

    private var findResult: FindMatchResult {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return findMatchCache.value(
            for: FindMatchKey(query: q, updateCounter: messagesSlice.updateCounter)
        ) {
            guard !q.isEmpty else { return FindMatchResult(matches: [], matchedIds: []) }
            let matches = messagesSlice.messages.filter {
                $0.body.localizedCaseInsensitiveContains(q)
                    || $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.detail?.localizedCaseInsensitiveContains(q) == true)
            }
            return FindMatchResult(matches: matches, matchedIds: Set(matches.map(\.id)))
        }
    }

    private var findMatches: [SessionChatStore.ChatMessage] {
        findResult.matches
    }

    private func transcriptFindBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.fg3)
            TextField("Find in transcript", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { jumpToFindMatch(proxy, delta: 1) }
                .accessibilityLabel("Find in transcript")
            Text(findStatusLabel)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(t.fg3)
                .frame(minWidth: 54, alignment: .trailing)
            Button(action: { jumpToFindMatch(proxy, delta: -1) }) {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(findMatches.isEmpty)
            .help("Previous match (⌘⇧G)")
            .accessibilityLabel("Previous match")
            Button(action: { jumpToFindMatch(proxy, delta: 1) }) {
                Image(systemName: "chevron.down")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(findMatches.isEmpty)
            .help("Next match (⌘G)")
            .accessibilityLabel("Next match")
            Button(action: {
                findQuery = ""
                selectedMatchIndex = nil
                showingFindBar = false
            }) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .font(TahoeFont.body(12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
    }

    private var findStatusLabel: String {
        let matches = findMatches
        guard !matches.isEmpty else {
            return findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "0"
        }
        let current = (selectedMatchIndex ?? 0) + 1
        return "\(current)/\(matches.count)"
    }

    private func jumpToFindMatch(_ proxy: ScrollViewProxy, delta: Int) {
        let matches = findMatches
        guard !matches.isEmpty else {
            showingFindBar = true
            findFocused = true
            return
        }
        let current = selectedMatchIndex ?? (delta < 0 ? 0 : -1)
        let next = (current + delta + matches.count) % matches.count
        selectedMatchIndex = next
        userPinnedToBottom = false
        let message = matches[next]
        if let anchor = transcriptProjection.anchorByMessageId[message.id] {
            if anchor.isHidden {
                expanded.insert(anchor.turnId)
                if let runId = anchor.runId {
                    expanded.insert("run:\(runId)")
                }
                if let pairId = anchor.pairId {
                    expanded.insert("pair:\(pairId)")
                }
            }
            Task { @MainActor in
                await Task.yield()
                scrollTranscript(proxy, to: anchor.itemId, anchor: .center)
            }
        } else {
            scrollTranscript(proxy, to: message.id, anchor: .center)
        }
    }

    private func jumpToMessage(_ proxy: ScrollViewProxy, messageId: String) {
        userPinnedToBottom = false
        unreadWhileReading = 0
        if let anchor = transcriptProjection.anchorByMessageId[messageId] {
            if anchor.isHidden {
                expanded.insert(anchor.turnId)
                if let runId = anchor.runId {
                    expanded.insert("run:\(runId)")
                }
                if let pairId = anchor.pairId {
                    expanded.insert("pair:\(pairId)")
                }
            }
            Task { @MainActor in
                await Task.yield()
                scrollTranscript(proxy, to: anchor.itemId, anchor: .top)
            }
        } else {
            scrollTranscript(proxy, to: messageId, anchor: .top)
        }
    }

    private func jumpToLastUserMessage(_ proxy: ScrollViewProxy) {
        var previous: SessionChatStore.ChatMessage?
        var lastPrompt: SessionChatStore.ChatMessage?
        for message in messagesSlice.messages {
            if PromptBoundary.isRealPrompt(message, previous: previous) {
                lastPrompt = message
            }
            previous = message
        }
        guard let message = lastPrompt else { return }
        userPinnedToBottom = false
        if let anchor = transcriptProjection.anchorByMessageId[message.id] {
            if anchor.isHidden {
                expanded.insert(anchor.turnId)
            }
            Task { @MainActor in
                await Task.yield()
                scrollTranscript(proxy, to: anchor.itemId, anchor: .center)
            }
        } else {
            scrollTranscript(proxy, to: message.id, anchor: .center)
        }
    }

    private func scrollTranscript(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private var loadEarlierButton: some View {
        HStack {
            Spacer()
            Button {
                guard !isLoadingEarlierHistory else { return }
                isLoadingEarlierHistory = true
                userPinnedToBottom = false
                Task {
                    await store.loadOlderHistory()
                    await MainActor.run {
                        isLoadingEarlierHistory = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isLoadingEarlierHistory {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isLoadingEarlierHistory ? "Loading earlier…" : "Load earlier messages")
                        .font(TahoeFont.body(11, weight: .semibold))
                }
                .foregroundStyle(t.fg3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(t.hair2, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isLoadingEarlierHistory)
            .help("Load the previous 200 messages")
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func stickToBottomIfPinned(_ proxy: ScrollViewProxy, updateCounter: UInt64) {
        let items = messagesSlice.items.count
        let previousItems = lastScrollItemCount
        lastScrollItemCount = items
        guard !isLoadingEarlierHistory else { return }
        if !userPinnedToBottom && items > previousItems {
            unreadWhileReading += items - previousItems
        }
        guard userPinnedToBottom, items >= previousItems else { return }
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await jumpToBottom(proxy, animated: false)
        }
    }

    @MainActor
    private func jumpToBottom(_ proxy: ScrollViewProxy, animated: Bool) async {
        suppressBottomGeometryUntil = Date().addingTimeInterval(0.35)
        userPinnedToBottom = true
        unreadWhileReading = 0
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
            }
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        userPinnedToBottom = true
    }

    /// One row in the thread. Either a plain user/assistant/meta message, or
    // ChatItem + ToolPair now live in ClawdmeterShared (T1 extraction).
    // Views read `store.snapshot.items` directly — no per-render walk.

    // MARK: - A9 row construction
    //
    // Rendering of a single `ChatItem` row was lifted into
    // `ChatItemRowView` (and its streaming-tail twin
    // `StreamingMessageView`) in `ChatItemRowView.swift`. The helpers
    // below build the value-typed payload + closure surface those
    // views need, projecting the parent's `@State` / `@ObservedObject`
    // dependencies into a flat snapshot the row can compare via `==`.
    //
    // The streaming tail is the LAST item in `messagesSlice.items`
    // when `liveStatusSlice.currentTurnState == .streaming`. We
    // surface its id once per body pass (see `streamingTailItemId`
    // below) and route the matching row through `StreamingMessageView`
    // so its body invalidations land under a distinct counter label.

    /// The id of the actively-streaming row, if any. `nil` when the
    /// turn is idle or completed — i.e., when no row should be
    /// treated specially.
    ///
    /// Computed once per parent body pass so we don't re-walk
    /// `items` per row. Cheap: `items.last?.id` is O(1), and
    /// `currentTurnState` is a plain enum read off the slice.
    private var streamingTailItemId: String? {
        guard liveStatusSlice.currentTurnState == .streaming else { return nil }
        return messagesSlice.items.last?.id
    }

    /// Build the SwiftUI view for one row. Returns either a
    /// `StreamingMessageView` (the tail row during an active turn)
    /// or a `ChatItemRowView` (everything else). Both delegate to
    /// the same `ChatItemRowContent` so visual presentation is
    /// identical.
    @ViewBuilder
    private func rowView(for item: ChatItem, streamingTailId: String?) -> some View {
        let payload = makeRowPayload(item: item, isStreamingTail: item.id == streamingTailId)
        let actions = rowActions
        if item.id == streamingTailId {
            StreamingMessageView(payload: payload, actions: actions)
        } else {
            ChatItemRowView(payload: payload, actions: actions)
        }
    }

    @ViewBuilder
    private func collapsedTurnView(_ turn: TranscriptTurn, streamingTailId: String?) -> some View {
        if turn.prompt == nil {
            ForEach(turn.visibleItems) { item in
                rowView(for: item, streamingTailId: streamingTailId)
                    .id(item.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(turnPromptItems(turn)) { item in
                    rowView(for: item, streamingTailId: streamingTailId)
                        .id(item.id)
                        .background(messagePositionReporter(for: item))
                }
                collapsedDisclosureRow(turn)
                    .id("\(turn.id):disclosure")
                if turn.hasCollapsedContent, expanded.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in
                        rowView(for: item, streamingTailId: streamingTailId)
                            .id(item.id)
                    }
                }
                ForEach(turnFinalItems(turn)) { item in
                    rowView(for: item, streamingTailId: streamingTailId)
                        .id(item.id)
                }
                turnChipStrip(turn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func messagePositionReporter(for item: ChatItem) -> some View {
        if case .message(let message) = item, message.kind == .userText {
            GeometryReader { geo in
                Color.clear.preference(
                    key: TranscriptMessagePositionKey.self,
                    value: [message.id: geo.frame(in: .named("transcriptScroll")).minY]
                )
            }
        }
    }

    private func turnPromptItems(_ turn: TranscriptTurn) -> [ChatItem] {
        guard let promptId = turn.prompt?.id else { return [] }
        return turn.visibleItems.filter { item in
            if case .message(let message) = item { return message.id == promptId }
            return false
        }
    }

    private func turnFinalItems(_ turn: TranscriptTurn) -> [ChatItem] {
        let promptId = turn.prompt?.id
        guard let finalId = turn.finalAssistant?.id, finalId != promptId else {
            return turn.visibleItems.filter { item in
                if case .message(let message) = item { return message.id != promptId }
                return true
            }
        }
        return turn.visibleItems.filter { item in
            if case .message(let message) = item { return message.id != promptId }
            return true
        }
    }

    @ViewBuilder
    private func collapsedDisclosureRow(_ turn: TranscriptTurn) -> some View {
        let isOpen = expanded.contains(turn.id)
        if turn.hasCollapsedContent {
            Button {
                if isOpen {
                    expanded.remove(turn.id)
                } else {
                    expanded.insert(turn.id)
                }
            } label: {
                collapsedDisclosureLabel(
                    turn,
                    icon: isOpen ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(PressableButtonStyle())
            .help(isOpen ? "Collapse hidden transcript rows" : "Show hidden transcript rows")
        } else {
            collapsedDisclosureLabel(turn, icon: "clock")
                .help(turn.summary.disclosureLabel)
        }
    }

    private func collapsedDisclosureLabel(_ turn: TranscriptTurn, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(t.fg4)
                .frame(width: 10)
            Text(turn.summary.disclosureLabel)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(t.hair2, in: Capsule(style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func turnChipStrip(_ turn: TranscriptTurn) -> some View {
        let artifacts = turn.outputArtifacts
        let files = turn.editedFiles
        if turn.finalAssistant != nil || !artifacts.isEmpty || !files.isEmpty {
            HStack(spacing: 8) {
                if turn.finalAssistant != nil {
                    Button {
                        onPreviewTurn()
                    } label: {
                        transcriptChip(
                            icon: WorkbenchPaneTab.browser.systemImage,
                            title: "Preview",
                            tint: SessionsV2Theme.accent
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Open the current worktree preview")
                    .accessibilityIdentifier("code.turn.preview")
                }
                ForEach(artifacts.prefix(6)) { artifact in
                    Button {
                        openTranscriptArtifact(artifact)
                    } label: {
                        transcriptChip(
                            icon: iconName(for: artifact.kind),
                            title: artifact.filename,
                            tint: artifact.kind == .markdown ? t.accent : t.fg3
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help(helpText(for: artifact))
                }
                ForEach(files.prefix(6)) { file in
                    transcriptChip(
                        icon: "pencil.and.scribble",
                        title: "\(file.basename) \(editDeltaLabel(file))",
                        tint: SessionsV2Theme.success
                    )
                    .help(file.filePath)
                }
            }
            .padding(.leading, 38)
            .padding(.top, 2)
        }
    }

    private func transcriptChip(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(t.hair2, in: Capsule(style: .continuous))
    }

    /// Project the parent's observed state into a value-typed
    /// payload the row view can compare via `==`. Building this once
    /// per row per body pass is cheap — every field is either a
    /// direct property read or a small dict subscript.
    private func makeRowPayload(item: ChatItem, isStreamingTail: Bool) -> ChatItemRowPayload {
        let isBookmarked: Bool
        let highlight: ChatItemRowPayload.HighlightState
        switch item {
        case .message(let m):
            isBookmarked = presentationStore.snapshot.messageBookmarks[session.id]?.contains(m.id) == true
            highlight = highlightState(for: m)
        case .toolRun:
            isBookmarked = false
            highlight = .none
        }

        // Project per-row tool-run / pair expansion state. Restricting
        // to keys we care about keeps the row's `==` cheap and means
        // toggling an unrelated row's disclosure doesn't bump this
        // row's equality fingerprint.
        let isToolRunOpen: Bool
        let pairsOpen: [String: Bool]
        if case .toolRun(let runId, let pairs) = item {
            isToolRunOpen = expanded.contains("run:\(runId)")
            var open: [String: Bool] = [:]
            for pair in pairs {
                open[pair.id] = expanded.contains("pair:\(pair.id)")
            }
            pairsOpen = open
        } else {
            isToolRunOpen = false
            pairsOpen = [:]
        }

        // AskUserQuestion selections — only the entries that belong
        // to this row's tool pairs. Same per-row narrowing as above.
        var askForRow: [String: [String: Set<String>]] = [:]
        if case .toolRun(_, let pairs) = item {
            for pair in pairs where pair.call.askUserQuestion != nil {
                if let sel = askUserQuestionSelections[pair.id] {
                    askForRow[pair.id] = sel
                }
            }
        }

        return ChatItemRowPayload(
            item: item,
            density: density,
            isBookmarked: isBookmarked,
            highlight: highlight,
            providerGlyph: session.tahoeProvider,
            repoRoot: transcriptPathRoot,
            syntaxTheme: presentationStore.snapshot.syntaxTheme,
            isToolRunOpen: isToolRunOpen,
            toolPairsOpen: pairsOpen,
            askSelections: askForRow,
            isStreamingTail: isStreamingTail,
            modelFailureRetryPrompt: modelFailureRetryPrompt(for: item, isStreamingTail: isStreamingTail)
        )
    }

    private func modelFailureRetryPrompt(for item: ChatItem, isStreamingTail: Bool) -> String? {
        guard case .message(let message) = item else { return nil }
        guard message.isError else { return nil }
        let retryPrompt = ModelFailureRecovery.retryPrompt(
            forErrorMessageId: message.id,
            in: messagesSlice.items
        )
        guard ModelFailureRecovery.shouldOfferRetryActions(
            message: message,
            isStreamingTail: isStreamingTail,
            turnState: liveStatusSlice.currentTurnState,
            isReadOnly: isReadOnly,
            retryPrompt: retryPrompt
        ) else { return nil }
        return retryPrompt
    }

    /// Closures the row fires for user interactions. We bind to the
    /// `@State` projections (`$expanded`, `$askUserQuestionSelections`)
    /// via local Bindings captured by the closures — Bindings are
    /// reference-stable wrappers around the @State storage, so the
    /// closure can mutate the state without itself being a mutating
    /// function. Same pattern SwiftUI uses everywhere for "set my
    /// state from a child view's action."
    ///
    /// The closures themselves are reference-stable across body re-
    /// evals (no @State observed inside them), so they're SAFE to
    /// exclude from `ChatItemRowView`'s `==` — and we MUST exclude
    /// them, otherwise the row would never short-circuit body
    /// re-evaluation.
    private var rowActions: ChatItemRowActions {
        let expandedBinding = $expanded
        let askBinding = $askUserQuestionSelections
        let presentationStore = self.presentationStore
        let sessionId = session.id
        let session = self.session
        let model = self.model
        return ChatItemRowActions(
            onToggleToolRun: { runId, shouldOpen in
                let key = "run:\(runId)"
                if shouldOpen {
                    expandedBinding.wrappedValue.insert(key)
                } else {
                    expandedBinding.wrappedValue.remove(key)
                }
            },
            onToggleToolPair: { pairId, shouldOpen in
                let key = "pair:\(pairId)"
                if shouldOpen {
                    expandedBinding.wrappedValue.insert(key)
                } else {
                    expandedBinding.wrappedValue.remove(key)
                }
            },
            onUpdateAskSelections: { pairId, sel in
                askBinding.wrappedValue[pairId] = sel
            },
            onAnswerAsk: { answer in
                Self.sendAnswerToSession(answer, sessionId: sessionId)
            },
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onQuoteReply: { body in
                let quoted = body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                ComposerInsertionInbox.shared.enqueue(text: "\(quoted)\n\n", autoSend: false)
            },
            onToggleBookmark: { messageId in
                try? presentationStore.toggleMessageBookmark(sessionId: sessionId, messageId: messageId)
            },
            onOpenMarkdownDocument: { path in
                model.openWorkspaceDocumentTab(from: session, path: path)
            },
            onRetryFailedTurn: onRetryFailedTurn,
            onRetryFailedTurnInNewChat: onRetryFailedTurnInNewChat
        )
    }

    /// Project the find-bar highlight state for a message to one of
    /// three discrete cases. Pre-computed once per body pass so the
    /// row's `==` doesn't have to walk the full match array.
    private func highlightState(for msg: SessionChatStore.ChatMessage) -> ChatItemRowPayload.HighlightState {
        let result = findResult
        guard !result.matchedIds.isEmpty,
              result.matchedIds.contains(msg.id)
        else { return .none }
        if let selectedMatchIndex,
           result.matches.indices.contains(selectedMatchIndex),
           result.matches[selectedMatchIndex].id == msg.id {
            return .selectedMatch
        }
        return .match
    }

    private var transcriptPathRoot: URL? {
        for raw in [session.runtimeCwd, session.worktreePath, session.repoKey] {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }
        return nil
    }

    private func openTranscriptArtifact(_ artifact: TranscriptOutputArtifact) {
        if artifact.kind == .markdown {
            model.openWorkspaceDocumentTab(from: session, path: artifact.path)
            return
        }
        guard let url = resolvedTranscriptArtifactURL(artifact.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolvedTranscriptArtifactURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let root = transcriptPathRoot {
            return root.appendingPathComponent(trimmed)
        }
        return URL(fileURLWithPath: trimmed)
    }

    private func helpText(for artifact: TranscriptOutputArtifact) -> String {
        switch artifact.kind {
        case .markdown:
            return "Open Markdown document in Code tab"
        case .html, .image, .pdf, .document, .spreadsheet, .presentation, .media, .archive, .data:
            return "Open \(artifact.path)"
        }
    }

    private func iconName(for kind: TranscriptArtifactKind) -> String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .html: return "safari"
        case .image: return "photo"
        case .pdf: return "doc.text.magnifyingglass"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .media: return "play.rectangle"
        case .archive: return "archivebox"
        case .data: return "tablecells.badge.ellipsis"
        }
    }

    private func editDeltaLabel(_ file: TranscriptEditedFile) -> String {
        TranscriptEditedFileFormatting.deltaLabel(
            additions: file.additions,
            deletions: file.deletions
        )
    }

    /// v0.5.6 — fire-and-forget answer send for AskUserQuestion. Mirrors
    /// the existing MacComposerSender path used by the main composer;
    /// loopback HTTP to the local daemon's `/sessions/:id/send`, which
    /// routes through the same rate-limit + audit-log path as a typed
    /// prompt.
    ///
    /// Static so the row's action closure can call it without holding
    /// a reference back to `ChatThreadScroll` — the closure captures
    /// only `sessionId: UUID`, a value type.
    private static func sendAnswerToSession(_ answer: String, sessionId: UUID) {
        guard !answer.isEmpty,
              let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort else { return }
        let sender = MacComposerSender(port: Int(port), token: (AppDelegate.runtime?.agentControlServer.localLoopbackToken ?? ""))
        Task {
            try? await sender.send(sessionId: sessionId, body: answer, asFollowUp: true)
        }
    }
}
