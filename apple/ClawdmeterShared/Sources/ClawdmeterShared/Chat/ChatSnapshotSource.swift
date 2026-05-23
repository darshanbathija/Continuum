import Foundation
#if canImport(Combine)
import Combine
#endif

/// Cross-platform view onto a per-session chat snapshot, conformed by
/// both Mac's `SessionChatStore` and iOS's `iOSChatStore`. The Chat V2
/// SwiftUI views bind to this protocol so the same `MacChatV2View` /
/// `IOSChatV2View` decomposition reads the same fields on either
/// platform — there's no shared concrete store because Mac's daemon-
/// side `SessionChatStore` owns Mac-only ingestor wiring that can't
/// live in `ClawdmeterShared`, and iOS's `iOSChatStore` is an LRU-2
/// mirror with its own backoff ladder.
///
/// Conformers MUST be `@MainActor ObservableObject` so SwiftUI
/// `@ObservedObject` subscribes to `objectWillChange` whenever the
/// underlying snapshot mutates. Read access happens through computed
/// properties below — both stores already hold this state under
/// different field names; the protocol normalizes the shape without
/// forcing a struct rewrite.
///
/// Adding a new field to the protocol means adding it to both store
/// types' conformance extensions. Don't add behavior here — keep it
/// read-only state. Mutations stay on each platform's own store API
/// (Mac dispatches via the daemon; iOS dispatches via
/// `AgentControlClient`).
@MainActor
public protocol ChatSnapshotSource: ObservableObject {
    /// Stable identity for the conversation. Used as the SwiftUI
    /// `View.id(...)` so switching between conversations cleanly tears
    /// down the previous transcript's `LazyVStack`.
    var sessionId: UUID { get }

    /// The structured items the transcript renders. Order is daemon-
    /// emitted (chronological); UI may render in reverse.
    var items: [ChatItem] { get }

    /// Plan steps extracted from the assistant's prose (numbered-list
    /// detection). Drives the right-pane Plan Tracker. For the Deep
    /// Research trace block, V2 uses a separate provider-specific
    /// extractor (see `SessionChatStore.sourceEntries` for the URL
    /// half; the step half comes from the deep-research system
    /// prompt's `[research-step] N. ...` contract on Claude, and from
    /// `reasoning_summary` events on Codex SDK).
    var planSteps: [PlanStep] { get }

    /// Per-message source URLs extracted from `WebSearch` / `WebFetch`
    /// / `web_search` tool results. Drives the citations footer in the
    /// V2 Deep Research trace and the existing Sources pane.
    var sourceEntries: [SourceEntry] { get }

    /// CLI-side permission prompt awaiting user input. When non-nil,
    /// the V2 composer disables and the transcript scroll-anchors
    /// above the prompt card so the user can't miss it. Nil for SDK
    /// chats (those go through the daemon's per-backend permission
    /// channel, not tmux send-keys).
    var pendingPermissionPrompt: PendingPermissionPrompt? { get }

    /// Explicit per-turn lifecycle. The V2 status strip reads this to
    /// drive the stopwatch clamp and the Stop↔Send button transition.
    /// On wire-v13 daemons this stays at `.idle` (the decode-default);
    /// the V2 view falls back to a 2-second heartbeat heuristic when
    /// `AgentControlWireVersion.supportsTurnLifecycle(serverWireVersion:)`
    /// returns false.
    var currentTurnState: TurnState { get }

    /// Timestamp of the latest event the store has ingested. Used by
    /// the sidebar's live-indicator pulse (●/▢ when < 30s ago).
    var lastEventAt: Date? { get }

    /// Monotonic counter incremented on every snapshot mutation.
    /// SwiftUI views key their `.onChange(of:)` modifiers on this
    /// instead of `items.last?.id` (which changes identity per render
    /// and triggers redundant work).
    var updateCounter: UInt64 { get }
}

/// Defaults that let conformers omit fields when they haven't wired
/// the corresponding state yet. Currently used by iOS during the
/// transitional period before `iOSChatStore` ingests `currentTurnState`
/// from the WS frames (lands in T4 — turn lifecycle ingestor wiring).
public extension ChatSnapshotSource {
    var pendingPermissionPrompt: PendingPermissionPrompt? { nil }
    var currentTurnState: TurnState { .idle }
}
