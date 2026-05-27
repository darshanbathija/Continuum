import Foundation
import ClawdmeterShared

/// T12: iOS-side cache for the Mac daemon's path allow-list. iOS sheets
/// (Clone / Quick Start) read from this to pre-validate user-typed parent
/// paths so a bad path fails inline with an actionable message instead of
/// after a 403 round-trip. 5-minute TTL — if the Mac admin adds a new
/// scan root, iOS picks it up on the next refresh (or earlier when the
/// user pulls to refresh the workspace switcher).
@MainActor
public final class WorkspaceAllowListCache: ObservableObject {

    @Published public private(set) var snapshot: WorkspaceAllowListResponse?
    @Published public private(set) var lastError: String?

    /// 5-minute TTL — short enough that allow-list changes propagate fast,
    /// long enough that we don't hammer the daemon on every keystroke.
    public static let ttl: TimeInterval = 5 * 60

    private var fetchedAt: Date?
    private weak var client: AgentControlClient?

    public init(client: AgentControlClient? = nil) {
        self.client = client
    }

    public func attach(client: AgentControlClient) {
        self.client = client
    }

    /// Fetch a fresh allow-list if the cached entry is stale or missing.
    /// `force=true` always refetches.
    public func refresh(force: Bool = false) async {
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.ttl {
            return
        }
        guard let client else { return }
        if let resp = await client.fetchWorkspaceAllowList() {
            self.snapshot = resp
            self.fetchedAt = Date()
            self.lastError = nil
        } else {
            self.lastError = client.lastError
        }
    }

    /// Pre-validate a user-typed path against the cached allow-list. Returns
    /// `.success(path)` on accept or `.failure(reason)` on reject. When the
    /// cache hasn't been populated yet, accepts optimistically — the daemon
    /// will still gate the actual request.
    public enum ValidationResult: Sendable {
        case success(String)
        case failure(String)
    }
    public func validate(_ path: String) -> ValidationResult {
        guard let snapshot else { return ValidationResult.success(path) }
        let canonical = canonicalize(path)
        if canonical.isEmpty { return ValidationResult.failure("Path is empty.") }
        for denied in snapshot.deniedSubpaths {
            if isPath(canonical, underOrEqualTo: canonicalize(denied)) {
                return ValidationResult.failure("Path is under a denied location.")
            }
        }
        for allowed in snapshot.allowedRoots {
            if isPath(canonical, underOrEqualTo: canonicalize(allowed)) {
                return ValidationResult.success(canonical)
            }
        }
        let roots = snapshot.allowedRoots.joined(separator: ", ")
        return ValidationResult.failure("Path must be under one of: \(roots)")
    }

    private func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        var stripped = standardized
        while stripped.count > 1 && stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped
    }

    private func isPath(_ path: String, underOrEqualTo root: String) -> Bool {
        if path == root { return true }
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootWithSlash)
    }
}
