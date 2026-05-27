import XCTest
import SwiftUI
import AppKit
import ClawdmeterShared
@testable import Clawdmeter

/// A9 acceptance gate — instrument `ChatItemRowView.body` and
/// `StreamingMessageView.body` with `BodyInvalidationCounter` and
/// assert the per-token-burst invalidation budget.
///
/// **What changed in A9:** the chat transcript's `ForEach` closure
/// used to render each row inline inside `ChatThreadScroll.body`. On
/// every token tick `messagesSlice.items` re-publishes (snapshot
/// publishing is N-wide; A5 sliced *which slice* publishes but not
/// the items array shape), so the parent body re-runs and the
/// closure constructs a view tree for every row — including the
/// historical ones whose payload hasn't moved.
///
/// A9 extracts the row into a struct view (`ChatItemRowView`)
/// conforming to `Equatable`. SwiftUI's diffing short-circuits at
/// `==` and skips body evaluation when the row's value-typed
/// payload is unchanged. The actively-streaming bubble takes its
/// own wrapper view (`StreamingMessageView`) so the per-token body
/// run is measurable separately.
///
/// **Acceptance criterion** (per the plan + the A9 ticket):
///   • `StreamingMessageView.body` invalidations ≈ N during an
///     N-token burst (one body per token).
///   • `ChatItemRowView.body` (historical rows) does NOT scale with
///     the burst length. The strong form is "zero re-evals during
///     the burst"; the realistic form (which we assert) is "the
///     count stays bounded by the number of distinct historical
///     row payloads SwiftUI mounted, which is set once at first
///     render and doesn't grow per token."
///
/// **How we drive a burst without a JSONL tail:** we mount the
/// view via `NSHostingView` and bind it to a `BurstScenario`
/// `@StateObject`. Each "tick" mutates the streaming row's body
/// string in the scenario, which republishes via SwiftUI's
/// observation graph. A short main-thread runloop spin after each
/// tick lets SwiftUI flush its renders.
///
/// **Plan reference:** A9 (Phase 2) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
@MainActor
final class ChatItemRowInvalidationTests: XCTestCase {

    /// Number of historical rows below the streaming tail. Sized to
    /// catch the regression we're guarding against: if any historical
    /// row's body fires per token, the count blows up linearly. 50 is
    /// large enough that "linear scaling" would yield 5000 invalidations
    /// for a 100-token burst — easy to distinguish from the bounded
    /// initial-mount baseline.
    private let historicalRowCount = 50

    /// Token-tick count for the simulated burst. Matches the A9
    /// ticket's "100-token burst" acceptance.
    private let burstTickCount = 100

    override func setUp() async throws {
        try await super.setUp()
        BodyInvalidationCounter.resetAll()
        BodyInvalidationCounter.enabled = true
    }

    override func tearDown() async throws {
        BodyInvalidationCounter.enabled = false
        BodyInvalidationCounter.resetAll()
        try await super.tearDown()
    }

    // MARK: - Pure Equatable shortcut (no view hosting)

    /// Sanity check: with identical payloads, `ChatItemRowView == lhs`
    /// returns true so SwiftUI knows it can skip body. Doesn't exercise
    /// the rendering engine — that's the next test — but proves the
    /// Equatable conformance is wired right, which is the precondition
    /// for SwiftUI to ever skip body.
    func test_equatable_identicalPayload_compareEqual() {
        let payload = makeMessagePayload(id: "m1", body: "hello", isStreamingTail: false)
        let actions = makeNoopActions()
        let a = ChatItemRowView(payload: payload, actions: actions)
        let b = ChatItemRowView(payload: payload, actions: actions)
        XCTAssertEqual(a, b,
            "Two ChatItemRowView instances with the same payload must compare equal so SwiftUI can skip body re-eval.")
    }

    func test_equatable_ignoresMarkdownOpenClosure() {
        let payload = makeMessagePayload(id: "m1", body: "hello", isStreamingTail: false)
        let a = ChatItemRowView(
            payload: payload,
            actions: makeNoopActions(onOpenMarkdownDocument: { _ in })
        )
        let b = ChatItemRowView(
            payload: payload,
            actions: makeNoopActions(onOpenMarkdownDocument: { _ in XCTFail("closure should not participate in equality") })
        )

        XCTAssertEqual(a, b,
            "Markdown document opening must stay on ChatItemRowActions; putting it in the payload would make identical rows compare unequal.")
    }

    /// Body-changing payloads must compare unequal — otherwise SwiftUI
    /// would erroneously skip re-rendering when the message body grows.
    func test_equatable_changedBody_compareUnequal() {
        let p1 = makeMessagePayload(id: "m1", body: "hello", isStreamingTail: false)
        let p2 = makeMessagePayload(id: "m1", body: "hello world", isStreamingTail: false)
        let actions = makeNoopActions()
        let a = ChatItemRowView(payload: p1, actions: actions)
        let b = ChatItemRowView(payload: p2, actions: actions)
        XCTAssertNotEqual(a, b,
            "A streaming token tick that grows the message body MUST flip ChatItemRowView's Equatable so the bubble re-renders.")
    }

    /// The streaming-tail flag flips at turn boundary. Same row id,
    /// same body, but `isStreamingTail` goes true→false → row's `==`
    /// must return false so SwiftUI does one final repaint to commit
    /// the tail.
    func test_equatable_streamingTailFlag_compareUnequal() {
        let p1 = makeMessagePayload(id: "m1", body: "final answer", isStreamingTail: true)
        let p2 = makeMessagePayload(id: "m1", body: "final answer", isStreamingTail: false)
        XCTAssertNotEqual(p1, p2,
            "isStreamingTail flips when the turn commits; the row payload must reflect that for the final repaint.")
    }

    // MARK: - Live SwiftUI hosting — body invalidation counts

    /// **The A9 acceptance test.** Mount the burst scenario in an
    /// `NSHostingView`, simulate a 100-token streaming burst, and
    /// assert the body invalidation counts:
    ///   • `StreamingMessageView.body` runs ≈ once per token.
    ///   • `ChatItemRowView.body` does NOT scale with the burst
    ///     length — the count stays bounded by the historical row
    ///     count (one body per row at initial mount, plus a small
    ///     constant for SwiftUI's own bookkeeping).
    func test_streamingBurst_historicalRows_stayFlat() async throws {
        let scenario = BurstScenario(
            historicalCount: historicalRowCount,
            initialStreamingBody: ""
        )

        // Mount the host. The hosting view runs SwiftUI's render loop
        // on the main runloop; without it, body evaluations are
        // deferred indefinitely and the counter never advances.
        let host = NSHostingView(rootView: ChatTranscriptBurstHarness(scenario: scenario))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        // Force initial layout pass so SwiftUI evaluates the body at
        // least once. Without this the counters stay at 0 until the
        // OS happens to draw the view.
        host.layoutSubtreeIfNeeded()
        await flush()

        // Capture the post-mount baseline. Any historical row body
        // calls from the initial render belong here, not to the
        // burst. The burst-window assertion compares the DELTA from
        // this baseline.
        let historicalBaseline = BodyInvalidationCounter.count(for: "ChatItemRowView")
        let streamingBaseline = BodyInvalidationCounter.count(for: "StreamingMessageView")

        // Drive the burst. Each iteration appends one "token" to the
        // streaming row's body. The hosting view should re-render the
        // streaming bubble on every tick and skip the historical
        // rows.
        for i in 0..<burstTickCount {
            scenario.appendToken("t\(i) ")
            // Per-tick runloop spin to let SwiftUI process the
            // observation update. SwiftUI batches per main-actor
            // hop, so one yield per tick keeps the burst monotone
            // (1 body per tick) rather than coalescing many ticks
            // into a single render.
            await flush()
        }

        let historicalAfter = BodyInvalidationCounter.count(for: "ChatItemRowView")
        let streamingAfter = BodyInvalidationCounter.count(for: "StreamingMessageView")

        let historicalDelta = historicalAfter - historicalBaseline
        let streamingDelta = streamingAfter - streamingBaseline

        // Surface the actual numbers in the test log so PR bodies +
        // CI logs carry the empirical baseline for this acceptance
        // gate, not just a pass/fail bit. Format mirrors the A6
        // BodyInvalidationCounter test diagnostics.
        print("[A9] BodyInvalidationCounter — burst test:")
        print("[A9]   historical row count : \(historicalRowCount)")
        print("[A9]   burst tick count     : \(burstTickCount)")
        print("[A9]   ChatItemRowView      : baseline=\(historicalBaseline) after=\(historicalAfter) delta=\(historicalDelta)")
        print("[A9]   StreamingMessageView : baseline=\(streamingBaseline) after=\(streamingAfter) delta=\(streamingDelta)")
        print("[A9]   naive baseline (ticks * rows)=\(burstTickCount * historicalRowCount)")
        print("[A9]   historical-row drop  : \(String(format: "%.4f", 1.0 - Double(historicalDelta) / Double(burstTickCount * historicalRowCount)))")

        // Streaming bubble: at least one body per tick. The exact
        // count can include extra renders SwiftUI scheduled for its
        // own bookkeeping (animation, hit-testing) so we assert a
        // lower-bound of ~1 per tick and an upper bound of 3×.
        XCTAssertGreaterThanOrEqual(streamingDelta, burstTickCount,
            "StreamingMessageView.body MUST run at least once per token tick (got \(streamingDelta) for \(burstTickCount) ticks). If it's lower, SwiftUI is coalescing renders and the streaming bubble visibly lags.")
        XCTAssertLessThanOrEqual(streamingDelta, burstTickCount * 3,
            "StreamingMessageView.body should run roughly once per token, not many times — high counts suggest the parent is invalidating the tail spuriously. Got \(streamingDelta) for \(burstTickCount) ticks.")

        // Historical rows: the count MUST NOT scale with the burst.
        // The strong form is "zero re-evals during the burst"; the
        // realistic form (which is what SwiftUI delivers for an
        // Equatable struct view) is bounded by some small constant.
        // We assert the delta is less than the historical row count
        // — meaning we got fewer than 1 re-eval per historical row
        // across the entire 100-tick burst, on average less than
        // 1% of the streaming rate.
        XCTAssertLessThan(historicalDelta, historicalRowCount,
            "A9 acceptance: historical ChatItemRowView bodies MUST stay flat during a streaming burst. Got delta=\(historicalDelta) over \(burstTickCount) ticks (baseline=\(historicalBaseline)). If this scales with ticks the Equatable shortcut isn't engaging.")
    }

    /// Variant of the burst test that asserts the invalidation DROP
    /// vs. a naive "every parent body invalidates every row" baseline.
    /// Mirrors the `test_acceptancePattern_invalidationDropMeasurement`
    /// shape from A6's BodyInvalidationCounterTests, applied to the A9
    /// streaming surface.
    func test_streamingBurst_invalidationDrop_meetsA9Threshold() async throws {
        let scenario = BurstScenario(
            historicalCount: historicalRowCount,
            initialStreamingBody: ""
        )
        let host = NSHostingView(rootView: ChatTranscriptBurstHarness(scenario: scenario))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        await flush()

        let historicalBaseline = BodyInvalidationCounter.count(for: "ChatItemRowView")

        for i in 0..<burstTickCount {
            scenario.appendToken("t\(i) ")
            await flush()
        }

        let historicalAfter = BodyInvalidationCounter.count(for: "ChatItemRowView")
        let historicalDelta = historicalAfter - historicalBaseline

        // Naive baseline: every parent body re-eval cascades to every
        // row → 100 ticks × 50 rows = 5000 row body invalidations.
        let naiveBaseline = burstTickCount * historicalRowCount
        let drop = 1.0 - Double(historicalDelta) / Double(naiveBaseline)

        // A9 sets the bar high: ≥99% drop. The actual achievable
        // drop with Equatable rows tends to be 100% (historicalDelta = 0)
        // on a fully-laid-out host; we allow some slop for SwiftUI's
        // internal bookkeeping.
        XCTAssertGreaterThanOrEqual(drop, 0.99,
            "A9 acceptance gate: ≥99% body-invalidation drop on historical rows during a streaming burst. Got drop=\(String(format: "%.4f", drop)) (historicalDelta=\(historicalDelta), naive=\(naiveBaseline)).")
    }

    // MARK: - Helpers

    /// Yield + spin the main runloop briefly so SwiftUI flushes
    /// queued renders. 5 ms is enough to drain one render batch
    /// without bloating the test suite's wall time (100 ticks × 5 ms
    /// = 500 ms per burst test).
    private func flush() async {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }

    private func makeMessagePayload(
        id: String,
        body: String,
        isStreamingTail: Bool
    ) -> ChatItemRowPayload {
        let msg = SessionChatStore.ChatMessage(
            id: id,
            kind: .assistantText,
            title: "Claude",
            body: body,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return ChatItemRowPayload(
            item: .message(msg),
            density: .balanced,
            isBookmarked: false,
            highlight: .none,
            providerGlyph: .claude,
            repoRoot: nil,
            syntaxTheme: .tahoe,
            isToolRunOpen: false,
            toolPairsOpen: [:],
            askSelections: [:],
            isStreamingTail: isStreamingTail
        )
    }

    private func makeNoopActions(onOpenMarkdownDocument: @escaping (String) -> Void = { _ in }) -> ChatItemRowActions {
        ChatItemRowActions(
            onToggleToolRun: { _, _ in },
            onToggleToolPair: { _, _ in },
            onUpdateAskSelections: { _, _ in },
            onAnswerAsk: { _ in },
            onCopy: { _ in },
            onQuoteReply: { _ in },
            onToggleBookmark: { _ in },
            onOpenMarkdownDocument: onOpenMarkdownDocument
        )
    }
}

// MARK: - Burst scenario

/// Minimal ObservableObject driving the burst test. Mirrors the
/// shape `ChatThreadScroll` consumes from `messagesSlice` — an
/// `items: [ChatItem]` array — without dragging the entire
/// `SessionChatStore` + JSONL tail into the test. The streaming
/// row is the last item; `appendToken` grows its body string.
@MainActor
final class BurstScenario: ObservableObject {
    @Published var items: [ChatItem]
    @Published var streamingBody: String

    private let historicalCount: Int

    init(historicalCount: Int, initialStreamingBody: String) {
        self.historicalCount = historicalCount
        self.streamingBody = initialStreamingBody
        // Pre-seed `items` with N historical assistant messages plus
        // one streaming-tail row. Each historical row gets a stable
        // id so SwiftUI's identity diffing doesn't churn across
        // renders — the whole point of the test is that identity-
        // stable rows skip body when their payload is unchanged.
        var built: [ChatItem] = []
        built.reserveCapacity(historicalCount + 1)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<historicalCount {
            let msg = SessionChatStore.ChatMessage(
                id: "hist-\(i)",
                kind: i.isMultiple(of: 2) ? .assistantText : .userText,
                title: i.isMultiple(of: 2) ? "Claude" : "You",
                body: "Historical message body \(i). Lorem ipsum dolor sit amet.",
                at: baseDate.addingTimeInterval(TimeInterval(i))
            )
            built.append(.message(msg))
        }
        // Streaming tail — id stays stable across the burst; only
        // body grows.
        let tail = SessionChatStore.ChatMessage(
            id: "streaming-tail",
            kind: .assistantText,
            title: "Claude",
            body: initialStreamingBody,
            at: baseDate.addingTimeInterval(TimeInterval(historicalCount))
        )
        built.append(.message(tail))
        self.items = built
    }

    func appendToken(_ token: String) {
        streamingBody += token
        // Rebuild only the tail item with the new body, then
        // re-publish the items array. This mirrors what the
        // SessionChatStore staging actor does on every token tick:
        // commit a new snapshot whose tail message's body is one
        // token longer.
        guard let lastIndex = items.indices.last,
              case .message(let oldTail) = items[lastIndex] else { return }
        let newTail = SessionChatStore.ChatMessage(
            id: oldTail.id,
            kind: oldTail.kind,
            title: oldTail.title,
            body: streamingBody,
            at: oldTail.at
        )
        items[lastIndex] = .message(newTail)
    }
}

// MARK: - SwiftUI harness

/// Test harness that mirrors the post-A9 `ChatThreadScroll`
/// rendering pattern at the minimum surface area needed to drive
/// body invalidations: a VStack containing N `ChatItemRowView`
/// historical rows and one `StreamingMessageView` tail.
///
/// We don't reuse `ChatThreadScroll` itself because instantiating
/// it requires a fully-wired `SessionChatStore` + `SessionsModel`
/// + `SessionPresentationStore` + a real session — far more setup
/// than the A9 acceptance question needs to answer. The harness's
/// rendering logic IS the production logic, just observed against
/// a `BurstScenario` instead of a chat store.
private struct ChatTranscriptBurstHarness: View {
    @ObservedObject var scenario: BurstScenario

    var body: some View {
        let lastId = scenario.items.last?.id
        // Eager `VStack` (not `LazyVStack`) so every row mounts and
        // SwiftUI evaluates body for all of them. The A9 invariant is
        // about per-row body invalidations during a streaming burst,
        // not about LazyVStack virtualization — using VStack here
        // gives a clean "every row gets evaluated" baseline so the
        // historical-vs-streaming counter delta is unambiguous.
        //
        // Production uses LazyVStack (which would only make this
        // assertion stronger: off-screen rows wouldn't even mount).
        // The Equatable shortcut we're verifying applies to both
        // VStack and LazyVStack — it's about SwiftUI's diff/render
        // semantics, which are the same in either container.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(scenario.items) { item in
                if item.id == lastId {
                    StreamingMessageView(
                        payload: payload(for: item, isStreamingTail: true),
                        actions: noopActions
                    )
                    .id(item.id)
                } else {
                    ChatItemRowView(
                        payload: payload(for: item, isStreamingTail: false),
                        actions: noopActions
                    )
                    .id(item.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func payload(for item: ChatItem, isStreamingTail: Bool) -> ChatItemRowPayload {
        ChatItemRowPayload(
            item: item,
            density: .balanced,
            isBookmarked: false,
            highlight: .none,
            providerGlyph: .claude,
            repoRoot: nil,
            syntaxTheme: .tahoe,
            isToolRunOpen: false,
            toolPairsOpen: [:],
            askSelections: [:],
            isStreamingTail: isStreamingTail
        )
    }

    private var noopActions: ChatItemRowActions {
        ChatItemRowActions(
            onToggleToolRun: { _, _ in },
            onToggleToolPair: { _, _ in },
            onUpdateAskSelections: { _, _ in },
            onAnswerAsk: { _ in },
            onCopy: { _ in },
            onQuoteReply: { _ in },
            onToggleBookmark: { _ in },
            onOpenMarkdownDocument: { _ in }
        )
    }
}
