import Foundation
#if canImport(Combine)
import Combine
#endif

/// Memoized derived store: caches the last computed `Output` for a given
/// `Input`, recomputing only when `Input` changes. Optionally runs the
/// compute closure off the main thread via `Task.detached(priority:)` so
/// heavy work doesn't block SwiftUI's render cycle, with an optional
/// placeholder surfaced while the off-main compute is in flight.
///
/// Consumed by:
///   - **A4** — memoize `AnalyticsDailyChart.costPoints` / `reqsPoints` /
///     `AnalyticsRepoList.rows` / `MacChatV2View.groupRows` (sync compute,
///     cache key = `(snapshot.computedAt, window, providerFilter)`).
///   - **C1** — move heavy chart-prep + pricing aggregation off-main with
///     skeleton placeholder during compute (detached compute, priority
///     `.utility`).
///   - **F1** — per-provider event normalization adapter (sync compute,
///     cache key per provider).
///
/// Design notes:
///   - `Input` is the FULL cache key. Pass a struct containing every value
///     that affects the output; this store doesn't know what your inputs
///     are — it just compares `Equatable` values.
///   - For SwiftUI binding, declare as `@StateObject` (or `@Observable`
///     post-C2). `output` is `@Published`; views rebind on every update.
///   - Default mode is `.sync` — compute runs inline on the calling actor
///     (typically `@MainActor` for view-driven updates). Pass
///     `.detached(priority:)` for off-main; the placeholder surfaces while
///     the detached worker runs, then the actual `output` once it lands.
///   - Cancellation: every `update(input:)` call cancels any in-flight
///     compute. A late-arriving result from a cancelled task is dropped via
///     `Task.isCancelled` check.
///
/// Example (A4 sync usage):
/// ```swift
/// struct ChartCacheKey: Equatable {
///     let snapshotComputedAt: Date
///     let window: TimeWindow
///     let providerFilter: ProviderFilter
/// }
///
/// @StateObject private var costPointsStore = MemoizedDerivedStore<ChartCacheKey, [CostPoint]>(
///     placeholder: [],
///     mode: .sync
/// ) { key in
///     // Pure derivation from the key; called only when the key changes.
///     buildCostPoints(snapshot: snapshot, window: key.window, filter: key.providerFilter)
/// }
/// ```
///
/// Example (C1 detached usage):
/// ```swift
/// @StateObject private var analyticsStore = MemoizedDerivedStore<ChartCacheKey, ChartFrame>(
///     placeholder: ChartFrame.skeleton(),
///     mode: .detached(priority: .utility)
/// ) { key in
///     // Heavy compute moved off-main; UI shows skeleton during this.
///     ChartFrame.compute(snapshot: snapshot, window: key.window)
/// }
/// ```
@MainActor
public final class MemoizedDerivedStore<Input: Equatable, Output>: ObservableObject {

    /// How the compute closure is scheduled.
    public enum ComputeMode: Sendable {
        /// Run compute inline on the main actor. Use for cheap derivations
        /// (target < 5ms). A4 uses this for chart `costPoints` / `rows`.
        case sync
        /// Run compute off the main actor via `Task.detached(priority:)`.
        /// C1 uses this for heavy chart-prep + pricing aggregation. While
        /// the detached task runs, `output` reads as the placeholder so
        /// the UI can show a skeleton.
        case detached(priority: TaskPriority)
    }

    /// Surfaced as `output` while no compute has landed yet AND while a
    /// `.detached` recompute is in flight. `nil` means "show nothing"
    /// (consumers should `if let output = store.output` to gate).
    public let placeholder: Output?

    /// How compute work is scheduled.
    public let mode: ComputeMode

    private let compute: @Sendable (Input) -> Output

    /// The latest derived value. `nil` (or `placeholder`) until the first
    /// compute completes. SwiftUI rebinds on every update via `@Published`.
    @Published public private(set) var output: Output?

    private var lastInput: Input?
    private var inflightTask: Task<Void, Never>?

    public init(
        placeholder: Output? = nil,
        mode: ComputeMode = .sync,
        compute: @escaping @Sendable (Input) -> Output
    ) {
        self.placeholder = placeholder
        self.mode = mode
        self.compute = compute
        self.output = placeholder
    }

    deinit {
        inflightTask?.cancel()
    }

    /// Update the input. If unchanged from the last call, nothing happens
    /// (cache hit). If changed, the in-flight compute is cancelled and a
    /// new compute is scheduled per the configured mode.
    public func update(input: Input) {
        if let lastInput, lastInput == input {
            // Cache hit — no work.
            return
        }
        lastInput = input
        inflightTask?.cancel()
        inflightTask = nil

        switch mode {
        case .sync:
            // Sync compute: run inline on the main actor. Caller observes
            // the new `output` immediately on return. Use only for cheap
            // derivations (target < 5ms).
            output = compute(input)

        case .detached(let priority):
            // Detached compute: clear to placeholder so the UI doesn't
            // show stale data while the worker is running, then bridge
            // the result back to the main actor on completion.
            output = placeholder
            let computeClosure = compute
            inflightTask = Task.detached(priority: priority) { [weak self] in
                let next = computeClosure(input)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Re-check cancellation after the main-actor hop: a
                    // newer `update(input:)` may have landed and cancelled
                    // this task between the pre-hop check and now. Without
                    // this gate, a stale result can briefly clobber the
                    // newer compute's placeholder/result (UI flicker).
                    if Task.isCancelled { return }
                    self.output = next
                }
            }
        }
    }

    /// Drop the cache and reset to placeholder. Useful when the upstream
    /// snapshot has a new identity but compares equal (rare), or when
    /// resetting between tests.
    public func invalidate() {
        lastInput = nil
        inflightTask?.cancel()
        inflightTask = nil
        output = placeholder
    }

    /// Is the configured compute currently running? Tests + diagnostics.
    public var isComputing: Bool {
        guard let inflightTask else { return false }
        return !inflightTask.isCancelled
    }
}
