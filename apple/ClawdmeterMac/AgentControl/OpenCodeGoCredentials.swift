import Foundation
import Security

/// Resolves OpenCode Go subscription credentials from env, auth.json, and
/// optional dashboard-scrape settings for quota polling.
enum OpenCodeGoCredentials {
    static let apiKeyEnv = "OPENCODE_API_KEY"
    static let workspaceEnv = "OPENCODE_GO_WORKSPACE_ID"
    static let authCookieEnv = "OPENCODE_GO_AUTH_COOKIE"
    static let workspaceDefaultsKey = "clawdmeter.opencode.go.workspaceId"
    static let authCookieDefaultsKey = "clawdmeter.opencode.go.authCookie"

    /// Provider ids written by `opencode auth login` for Go / Zen keys.
    static let authProviderIDs = ["opencode-go", "opencode"]

    /// API key used for Go model calls and future usage API probes.
    static func apiKey() async -> String? {
        if let key = apiKeyFromDisk(), !key.isEmpty { return key }
        return nil
    }

    /// Synchronous auth check for AISource / TokenProvider (env + auth.json).
    static func hasGoAuthFromDisk() -> Bool {
        apiKeyFromDisk() != nil
    }

    static func hasGoAuth() async -> Bool {
        await apiKey() != nil
    }

    private static func apiKeyFromDisk() -> String? {
        let env = ProcessInfo.processInfo.environment[apiKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        guard let data = try? Data(contentsOf: OpencodeAuthFile.fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return nil
        }
        for providerId in authProviderIDs {
            guard let entry = dict[providerId],
                  let type = entry["type"] as? String,
                  type == "api",
                  let key = entry["key"] as? String else { continue }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Dashboard scrape config for rolling / weekly / monthly quota windows.
    /// OpenCode has not shipped a public usage API yet; this mirrors the
    /// opencode-quota community scraper until `/zen/go/v1/usage` lands.
    ///
    /// The workspace ID is non-secret (it appears in the dashboard URL) and stays
    /// in UserDefaults; the auth COOKIE is a live session credential and lives in
    /// the Keychain (device-local), never in UserDefaults.
    static func dashboardQuotaConfig() -> (workspaceId: String, authCookie: String)? {
        migrateLegacyCookieIfNeeded()
        let envWorkspace = ProcessInfo.processInfo.environment[workspaceEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envCookie = ProcessInfo.processInfo.environment[authCookieEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envWorkspace, !envWorkspace.isEmpty,
           let envCookie, !envCookie.isEmpty {
            return (envWorkspace, envCookie)
        }
        let workspace = UserDefaults.standard.string(forKey: workspaceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = cookieKeychain.read()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace, !workspace.isEmpty,
              let cookie, !cookie.isEmpty else {
            return nil
        }
        return (workspace, cookie)
    }

    /// Persist quota-scrape creds. Returns false (and persists nothing) when the
    /// inputs are invalid, so a malformed paste can't reach the URL/header layer.
    @discardableResult
    static func saveDashboardQuotaConfig(workspaceId: String, authCookie: String) -> Bool {
        let workspace = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty, !cookie.isEmpty else { return false }
        // The workspace ID is interpolated into a URL path segment — constrain it
        // so a pasted value can't smuggle extra path/query/fragment.
        guard isValidWorkspaceId(workspace) else { return false }
        // Reject control characters before the cookie becomes a `Cookie:` header
        // value (CR/LF would be a header-injection vector).
        guard !cookie.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        UserDefaults.standard.set(workspace, forKey: workspaceDefaultsKey)
        cookieKeychain.write(cookie)
        return true
    }

    static func clearDashboardQuotaConfig() {
        UserDefaults.standard.removeObject(forKey: workspaceDefaultsKey)
        UserDefaults.standard.removeObject(forKey: authCookieDefaultsKey) // legacy plaintext slot
        cookieKeychain.delete()
    }

    /// Workspace IDs are alphanumeric + `-`/`_` (they index a dashboard URL path).
    static func isValidWorkspaceId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57)   // 0-9
                || (s.value >= 65 && s.value <= 90)   // A-Z
                || (s.value >= 97 && s.value <= 122)  // a-z
                || s == "-" || s == "_"
        }
    }

    /// One-time move of any cookie a prior build of this branch wrote to
    /// UserDefaults into the Keychain, then strip the plaintext copy.
    private static func migrateLegacyCookieIfNeeded() {
        guard let legacy = UserDefaults.standard.string(forKey: authCookieDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else { return }
        if cookieKeychain.read() == nil {
            cookieKeychain.write(legacy)
        }
        UserDefaults.standard.removeObject(forKey: authCookieDefaultsKey)
    }

    private static let cookieKeychain = OpenCodeGoKeychain(service: "com.clawdmeter.opencode.go.authCookie")
}

/// Minimal device-local Keychain string box for the OpenCode Go auth cookie.
/// No access group + `ThisDeviceOnly` — the cookie is a session credential that
/// must not sync to other devices or land in unencrypted UserDefaults backups.
private struct OpenCodeGoKeychain {
    let service: String

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    func read() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let update = SecItemUpdate(baseQuery() as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() {
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }
}
