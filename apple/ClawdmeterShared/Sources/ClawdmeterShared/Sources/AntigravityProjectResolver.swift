import Foundation
import OSLog

private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AntigravityProjectResolver")

/// Maps a Clawdmeter session's `repoKey` (canonical git-repo path) to
/// the Antigravity 2 project UUID it should run under.
///
/// `agentapi new-conversation` requires `ANTIGRAVITY_PROJECT_ID` env
/// var; without it, the call fails with
/// `failed to start cascade: rpc error: code = Unknown desc = project_id
/// is required when providing project_env_config`. So every spawn path
/// must look up which Antigravity project corresponds to the user's
/// repo cwd before invoking agentapi.
///
/// Phase 0.5 confirmed the on-disk shape of project records:
///
/// ```text
/// ~/.gemini/config/projects/<uuid>.json
/// {
///   "id":   "<uuid>",
///   "name": "CC Watch",
///   "projectResources": {
///     "resources": [
///       {
///         "gitFolder": {
///           "folderUri": "file:///Users/<user>/Downloads/CC%20Watch",
///           "allowWrite": true
///         }
///       }
///     ]
///   },
///   "settings": { /* approval policies — see AntigravityProjectSettings */ }
/// }
/// ```
///
/// Records with `projectResources == null` (e.g. the special
/// `outside-of-project.json` sentinel) are skipped — they have no
/// associated repo.
///
/// ### Match algorithm
///
/// ```text
/// projects/*.json ─┬─ projectResources.resources[*].gitFolder.folderUri
///                  │       ↓ (strip file:// + URL-decode)
///                  │   /Users/x/Downloads/CC Watch
///                  │       ↓
///                  │   RepoIdentity.normalize(_:)         ◄── shared
///                  │       ↓                                  with session
///                  │   RepoKey (canonical git-repo path)      lookup
///                  └────────────┐
///                               ↓
///                       cache: [RepoKey: ProjectInfo]
///                               ↓
///                       resolve(forRepoKey:) -> ProjectInfo?
/// ```
public actor AntigravityProjectResolver {

    public struct ProjectInfo: Sendable, Equatable, Hashable {
        /// Project UUID — feeds `ANTIGRAVITY_PROJECT_ID` env var on
        /// every agentapi invocation.
        public let id: String
        /// User-facing project name (e.g. "CC Watch"). Used in CTAs
        /// when surfacing ambiguity or read-only banners.
        public let name: String
        /// `gitFolder.allowWrite`. When `false`, Clawdmeter surfaces a
        /// read-only banner on the chat header — Antigravity restricts
        /// write tools regardless of approval mode.
        public let allowWrite: Bool
        /// The canonical repo path this project maps to. Same value as
        /// the `RepoKey` used by `RepoIdentity.normalize`.
        public let repoKey: String

        public init(id: String, name: String, allowWrite: Bool, repoKey: String) {
            self.id = id
            self.name = name
            self.allowWrite = allowWrite
            self.repoKey = repoKey
        }
    }

    public static let shared = AntigravityProjectResolver()

    /// Override for tests. Production reads from `~/.gemini/config/projects/`.
    public let projectsDir: URL

    private var cache: [String: ProjectInfo] = [:]
    private var indexedAt: Date?
    /// Refresh window: re-scan if cache is older than this. Projects
    /// are created infrequently (per user action), so 60s is generous
    /// but keeps us fresh enough for first-use after creating a new
    /// Antigravity project.
    private let cacheTTL: TimeInterval = 60

    public init(projectsDir: URL? = nil) {
        if let projectsDir {
            self.projectsDir = projectsDir
        } else {
            // homeDirectoryForCurrentUser is macOS-only; on iOS/Watch the
            // Antigravity install can't exist anyway, so fall back to
            // NSHomeDirectory() which is available everywhere. Callers on
            // non-mac targets just see an empty resolver (no projects).
            #if os(macOS)
            let home = FileManager.default.homeDirectoryForCurrentUser
            #else
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            #endif
            self.projectsDir = home
                .appendingPathComponent(".gemini")
                .appendingPathComponent("config")
                .appendingPathComponent("projects")
        }
    }

    /// Look up the Antigravity project for a given Clawdmeter
    /// `session.repoKey`. Returns `nil` when no matching project
    /// exists — caller surfaces the "Open this repo in Antigravity 2
    /// first" CTA.
    ///
    /// Refreshes the cache if older than `cacheTTL` or on first call.
    public func resolve(forRepoKey rawRepoKey: String) async -> ProjectInfo? {
        let normalized = RepoIdentity.normalize(rawRepoKey)
        if shouldRefresh() {
            indexProjects()
        }
        return cache[normalized]
    }

    /// Force a re-scan. Tests + manual triggers (e.g. user just
    /// created a new project in Antigravity, wants Clawdmeter to
    /// pick it up immediately).
    public func invalidate() {
        cache.removeAll()
        indexedAt = nil
    }

    /// Read-only snapshot of all projects this resolver knows about.
    /// Used by Settings → Antigravity Diagnostics for surfacing the
    /// project map.
    public func allProjects() async -> [ProjectInfo] {
        if shouldRefresh() {
            indexProjects()
        }
        return Array(cache.values)
    }

    // MARK: - Internal

    private func shouldRefresh() -> Bool {
        guard let indexedAt else { return true }
        return Date().timeIntervalSince(indexedAt) > cacheTTL
    }

    private func indexProjects() {
        var fresh: [String: ProjectInfo] = [:]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            // Antigravity hasn't created any projects yet — expected on a
            // fresh install. Treat as empty index without noise.
            indexedAt = Date()
            cache = [:]
            return
        } catch {
            logger.error("AntigravityProjectResolver.indexProjects: contentsOfDirectory \(self.projectsDir.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            indexedAt = Date()
            cache = [:]
            return
        }

        for url in urls where url.pathExtension == "json" {
            // Skip `outside-of-project.json` and any other sentinel files
            // that have null projectResources.
            guard let info = parseProject(at: url) else { continue }
            fresh[info.repoKey] = info
        }

        cache = fresh
        indexedAt = Date()
    }

    /// Parse a single `<uuid>.json` file. Returns `nil` when the file
    /// is the outside-of-project sentinel, has no resources, or fails
    /// to decode. Robust to schema additions Antigravity makes in the
    /// future — only the fields we care about are required.
    ///
    /// `nonisolated` because it doesn't touch actor state — read-only
    /// file parse. Tests call this directly to verify the field
    /// extraction logic without spinning through the async cache path.
    nonisolated func parseProject(at url: URL) -> ProjectInfo? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("AntigravityProjectResolver.parseProject read \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.debug("AntigravityProjectResolver.parseProject \(url.path, privacy: .public) is not a JSON object")
            return nil
        }

        guard let id = json["id"] as? String, !id.isEmpty,
              id != "outside-of-project"
        else { return nil }

        let name = (json["name"] as? String) ?? id

        // projectResources may be null for sentinels.
        guard let resources = json["projectResources"] as? [String: Any],
              let resourcesArray = resources["resources"] as? [[String: Any]],
              let firstResource = resourcesArray.first
        else { return nil }

        // Only `gitFolder` resources are mappable to a session.repoKey.
        // Antigravity may add other resource types (e.g. remote repos)
        // in future versions; ignore them silently.
        guard let gitFolder = firstResource["gitFolder"] as? [String: Any],
              let folderUri = gitFolder["folderUri"] as? String,
              !folderUri.isEmpty
        else { return nil }

        // gitFolder.allowWrite defaults to true when absent (some
        // older project records omit the key).
        let allowWrite = (gitFolder["allowWrite"] as? Bool) ?? true

        // Convert `file:///Users/.../CC%20Watch` → `/Users/.../CC Watch`.
        guard let decodedPath = Self.decodeFolderURI(folderUri) else { return nil }

        let repoKey = RepoIdentity.normalize(decodedPath)
        return ProjectInfo(
            id: id,
            name: name,
            allowWrite: allowWrite,
            repoKey: repoKey
        )
    }

    /// Strip `file://` prefix and URL-decode percent-escapes. Returns
    /// `nil` for malformed inputs.
    static func decodeFolderURI(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        // URL.path handles percent-decoding automatically.
        return url.path
    }

    /// Public re-export so callers (e.g. tests, Settings UI) don't
    /// need to construct a URL just to decode a folderUri.
    public nonisolated static func decodeURI(_ uri: String) -> String? {
        decodeFolderURI(uri)
    }
}
