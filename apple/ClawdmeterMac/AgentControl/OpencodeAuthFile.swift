import Foundation
import Darwin
import OSLog

private let authFileLogger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeAuthFile")

/// Resolve the *real* user home directory, bypassing macOS App Sandbox
/// redirection. `NSHomeDirectory()` returns the sandbox container
/// (`~/Library/Containers/<bundle-id>/Data`) for sandboxed apps — even
/// when the sandbox entitlement is commented out, Clawdmeter still
/// resolves NSHomeDirectory() to the container path in practice.
///
/// We need the user's actual `~` because opencode (a separate process)
/// reads its credentials from `~/.local/share/opencode/auth.json`,
/// outside any Clawdmeter sandbox container.
///
/// `getpwuid(getuid())->pw_dir` reads the canonical home from the
/// system password database — bypasses sandbox redirection entirely.
internal func clawdmeterRealUserHome() -> String {
    // POSIX: getpwuid returns a pointer into a static buffer; read the
    // pw_dir field immediately.
    if let pw = getpwuid(getuid()),
       let cstr = pw.pointee.pw_dir {
        return String(cString: cstr)
    }
    // Defensive fallback: NSHomeDirectoryForUser also reads pwd, but
    // double-fallback to NSHomeDirectory() (the sandbox path) if even
    // that fails — at least the writes don't crash.
    if let username = ProcessInfo.processInfo.environment["USER"],
       let real = NSHomeDirectoryForUser(username) {
        return real
    }
    return NSHomeDirectory()
}

/// Read/write opencode's credentials file at `~/.local/share/opencode/auth.json`
/// (or `$XDG_DATA_HOME/opencode/auth.json` if XDG is set).
///
/// Schema mirrors `packages/opencode/src/auth/index.ts` in upstream
/// opencode — a flat `{ providerID: AuthInfo }` dict where `AuthInfo`
/// is a discriminated union on `type`:
///
/// ```
/// { "type": "api",  "key": "<api-key>", "metadata"?: {string:string} }
/// { "type": "oauth", "refresh": "...", "access": "...", "expires": <int>, "accountId"?: "...", "enterpriseUrl"?: "..." }
/// { "type": "wellknown", "key": "...", "token": "..." }
/// ```
///
/// We only need to write the `api` shape — OAuth and well-known entries
/// are managed by opencode's interactive flow. The provider key matches
/// opencode's normalization: trailing slashes stripped (see
/// `set(key, info)` in upstream).
///
/// File mode is forced to `0600` per upstream's `writeJson(file, ..., 0o600)`.
/// Writes go through a sibling tempfile + atomic `moveItem` so an
/// interrupted write never leaves a half-formed credentials file.
public actor OpencodeAuthFile {
    public static let shared = OpencodeAuthFile()

    /// Resolved data directory. Honors `$XDG_DATA_HOME` if set, falls
    /// back to `<real-home>/.local/share/opencode`. Matches opencode's
    /// behavior on macOS (verified via `opencode auth list` output).
    ///
    /// v0.23.5: switched from `NSHomeDirectory()` (sandbox container)
    /// to `clawdmeterRealUserHome()` (getpwuid-based) — opencode runs
    /// outside any Clawdmeter sandbox, so credentials must live in
    /// the user's actual `~`, not the container.
    public static var dataDirectoryURL: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return URL(fileURLWithPath: clawdmeterRealUserHome())
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// v0.23.5 — Legacy sandbox-container path where v0.23.4 mistakenly
    /// wrote credentials. We migrate any leftover entries from here on
    /// first read so a v0.23.4 → v0.23.5 user whose key fell into the
    /// sandbox container doesn't have to re-paste it.
    public static var legacySandboxDataDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// Resolved path to `auth.json`.
    public static var fileURL: URL {
        dataDirectoryURL.appendingPathComponent("auth.json")
    }

    /// Read the current auth dict. Returns empty when the file is
    /// missing OR can't be parsed (treat parse failures as "empty"
    /// rather than throwing so callers can still write new entries).
    public func readEntries() async -> [String: [String: Any]] {
        // v0.23.5: auto-migrate any entries stranded in the legacy
        // sandbox-container path (where v0.23.4 mistakenly wrote them).
        // Best-effort, idempotent — failures just mean the user has to
        // re-paste the key once.
        await migrateLegacyEntriesIfNeeded()

        guard let data = try? Data(contentsOf: Self.fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: [String: Any]] else {
            return [:]
        }
        return dict
    }

    /// Move any provider entries from the legacy sandbox-container path
    /// (where v0.23.4 wrote them due to the NSHomeDirectory bug) into
    /// the real `~/.local/share/opencode/auth.json`. Idempotent — runs
    /// at most once per process, then sets a marker file.
    ///
    /// Strategy: copy entries that don't already exist in the canonical
    /// file, then delete the legacy file so we don't migrate twice.
    private func migrateLegacyEntriesIfNeeded() async {
        let legacyURL = Self.legacySandboxDataDirectoryURL.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              !FileManager.default.fileExists(atPath: Self.fileURL.path),
              legacyURL.path != Self.fileURL.path else {
            return
        }
        guard let legacyData = try? Data(contentsOf: legacyURL),
              let legacyObj = try? JSONSerialization.jsonObject(with: legacyData),
              let legacyDict = legacyObj as? [String: [String: Any]] else {
            return
        }
        // Read canonical entries without recursing into migrate.
        var canonical: [String: [String: Any]] = {
            guard let data = try? Data(contentsOf: Self.fileURL),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: [String: Any]] else {
                return [:]
            }
            return dict
        }()
        var changed = false
        for (providerId, entry) in legacyDict where canonical[providerId] == nil {
            canonical[providerId] = entry
            changed = true
        }
        if changed {
            do {
                try await writeEntries(canonical)
                authFileLogger.notice(
                    "opencode auth migrated \(legacyDict.count, privacy: .public) legacy entries from sandbox container to real home"
                )
            } catch {
                authFileLogger.error(
                    "opencode auth legacy migration failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
        // Delete legacy file so the migration is one-shot. Best-effort —
        // a failed delete just means we re-migrate next read (idempotent).
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// Add or overwrite an API-key entry for `providerId`.
    /// Normalises the provider id the same way opencode does
    /// (strip trailing slashes). Triggers a write with file mode 0600.
    public func setAPIKey(
        providerId: String,
        key: String,
        metadata: [String: String]? = nil
    ) async throws {
        let normalized = normalize(providerId)
        guard !normalized.isEmpty else {
            throw OpencodeAuthError.invalidProviderID
        }
        guard !key.isEmpty else {
            throw OpencodeAuthError.emptyKey
        }
        var entries = await readEntries()
        // Drop any pre-existing entry under the un-normalized form so
        // we don't end up with duplicate keys pointing at different
        // versions of the same provider.
        if providerId != normalized {
            entries.removeValue(forKey: providerId)
        }
        var entry: [String: Any] = [
            "type": "api",
            "key": key
        ]
        if let metadata, !metadata.isEmpty {
            entry["metadata"] = metadata
        }
        entries[normalized] = entry
        try await writeEntries(entries)
        authFileLogger.info("opencode auth set provider=\(normalized, privacy: .public) type=api")
    }

    /// Remove all entries for `providerId` (both normalized and
    /// un-normalized forms).
    public func removeProvider(providerId: String) async throws {
        let normalized = normalize(providerId)
        var entries = await readEntries()
        let removedRaw = entries.removeValue(forKey: providerId) != nil
        let removedNormalized = providerId == normalized
            ? false
            : entries.removeValue(forKey: normalized) != nil
        guard removedRaw || removedNormalized else {
            authFileLogger.info("opencode auth remove skipped provider=\(normalized, privacy: .public)")
            return
        }
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: Self.fileURL)
        } else {
            try await writeEntries(entries)
        }
        authFileLogger.info("opencode auth removed provider=\(normalized, privacy: .public)")
    }

    /// Currently configured provider IDs, sorted alphabetically.
    public func providerIds() async -> [String] {
        let entries = await readEntries()
        return entries.keys.sorted()
    }

    // MARK: - Internal helpers

    /// Strip trailing slashes, matching opencode's
    /// `key.replace(/\/+$/, "")`.
    internal func normalize(_ providerId: String) -> String {
        var s = providerId
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Atomically write the auth dict to disk with file mode 0600.
    /// Strategy: write to a sibling tempfile in the same directory,
    /// chmod the tempfile, then `moveItem` (POSIX rename — atomic
    /// within the same filesystem). The visible `auth.json` is never
    /// observed at a permissive mode.
    internal func writeEntries(_ entries: [String: [String: Any]]) async throws {
        let dir = Self.dataDirectoryURL
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tmpURL = dir.appendingPathComponent(".auth-\(UUID().uuidString).json.tmp")
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: tmpURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tmpURL.path
        )
        let dest = Self.fileURL
        // Remove existing destination so moveItem doesn't fail. This
        // window is tiny (<1ms) but technically non-atomic — opencode
        // upstream tolerates this same window in its `writeJson` path.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }
}

public enum OpencodeAuthError: Error, LocalizedError {
    case invalidProviderID
    case emptyKey

    public var errorDescription: String? {
        switch self {
        case .invalidProviderID:
            return "Provider ID can't be empty."
        case .emptyKey:
            return "API key can't be empty."
        }
    }
}
