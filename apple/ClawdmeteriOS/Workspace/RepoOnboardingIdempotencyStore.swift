import Foundation

/// Persistent idempotency-key store for the three iOS Add-Repo flows.
///
/// Why this exists: each sheet generates an idempotency key the daemon
/// uses to dedup retries. If the iPhone is killed AFTER the Mac completes
/// the clone/quick-start but BEFORE the response is observed, a `@State`-
/// only key disappears with the view, the user retries, gets a fresh
/// UUID, and the daemon doesn't recognize it — the side effect re-fires
/// (and fails with "destination exists"). Persisting the key per-flow
/// to `UserDefaults` survives app kill so the retry hits the same
/// idempotency slot in the daemon's bounded LRU cache.
///
/// Each flow has a single in-flight slot (no concurrent clones of
/// different repos sharing the same flow key). On successful completion
/// or final/non-retryable error, the slot is cleared so the user's NEXT
/// invocation of that flow starts fresh.
enum RepoOnboardingIdempotencyStore {
    enum Flow: String {
        case openLocal     = "clawdmeter.ios.add-repo.open-local.idempotency-key"
        case clone         = "clawdmeter.ios.add-repo.clone.idempotency-key"
        case quickStart    = "clawdmeter.ios.add-repo.quick-start.idempotency-key"
    }

    /// Returns the persisted key for `flow`, generating + persisting a
    /// fresh UUID if none is present. Idempotent — calling twice returns
    /// the same key.
    static func currentKey(for flow: Flow, store: UserDefaults = .standard) -> String {
        if let existing = store.string(forKey: flow.rawValue), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        store.set(new, forKey: flow.rawValue)
        return new
    }

    /// Clear the persisted key for `flow`. Call on successful completion
    /// or final error so the next attempt generates a new key.
    static func clear(_ flow: Flow, store: UserDefaults = .standard) {
        store.removeObject(forKey: flow.rawValue)
    }
}
