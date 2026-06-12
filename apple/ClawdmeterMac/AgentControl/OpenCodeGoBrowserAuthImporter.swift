#if os(macOS)
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import ClawdmeterShared

/// Reads opencode.ai dashboard credentials from Chromium browser stores.
///
/// The `auth` session cookie is encrypted with the browser's Safe Storage
/// password (e.g. `Chrome Safe Storage` in Keychain). Workspace IDs are
/// recovered from recent `opencode.ai/workspace/…` history URLs.
enum OpenCodeGoBrowserAuthImporter {
    struct Result: Sendable, Equatable {
        let workspaceId: String
        let authCookie: String
        let source: String
    }

    /// Best-effort import across installed Chromium profiles. Prompts for
    /// Keychain access once when `allowsUserInteraction` is true.
    static func importDashboardCredentials(allowsUserInteraction: Bool) -> Result? {
        for profile in chromiumProfiles() {
            guard let password = readSafeStoragePassword(
                service: profile.safeStorageService,
                account: profile.safeStorageAccount,
                allowsUserInteraction: allowsUserInteraction
            ) else { continue }
            guard let encrypted = readEncryptedCookie(
                cookiesURL: profile.cookiesURL,
                host: "opencode.ai",
                name: "auth"
            ) else { continue }
            guard let decrypted = decryptChromiumCookie(encrypted: encrypted, password: password) else { continue }
            let cookie = String(data: decrypted, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cookie, !cookie.isEmpty else { continue }
            guard !cookie.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { continue }

            let workspace = profile.historyURL.flatMap { readWorkspaceId(historyURL: $0) }
                ?? readWorkspaceIdFromAnyProfile()
            guard let workspace, OpenCodeGoCredentials.isValidWorkspaceId(workspace) else { continue }
            return Result(workspaceId: workspace, authCookie: cookie, source: profile.label)
        }
        return nil
    }

    /// Best-effort workspace id from saved settings or Chromium history.
    /// Does not touch Keychain — safe to call when opening the setup panel.
    static func discoverWorkspaceId() -> String? {
        let saved = UserDefaults.standard.string(forKey: OpenCodeGoCredentials.workspaceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty, OpenCodeGoCredentials.isValidWorkspaceId(saved) {
            return saved
        }
        return readWorkspaceIdFromAnyProfile()
    }

    /// Extracts `wrk_…` from `https://opencode.ai/workspace/{id}/…`.
    static func extractWorkspaceId(from url: String) -> String? {
        guard let range = url.range(of: "/workspace/") else { return nil }
        let tail = url[range.upperBound...]
        let id = tail.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? ""
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenCodeGoCredentials.isValidWorkspaceId(trimmed) else { return nil }
        return trimmed
    }

    // MARK: - Chromium profile discovery

    private struct ChromiumProfile {
        let label: String
        let cookiesURL: URL
        let historyURL: URL?
        let safeStorageService: String
        let safeStorageAccount: String
    }

    private static func chromiumProfiles() -> [ChromiumProfile] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        var profiles: [ChromiumProfile] = []
        profiles.append(contentsOf: discoverChromiumProfiles(
            root: appSupport.appendingPathComponent("Google/Chrome", isDirectory: true),
            labelPrefix: "Chrome",
            service: "Chrome Safe Storage",
            account: "Chrome"
        ))
        profiles.append(contentsOf: discoverChromiumProfiles(
            root: appSupport.appendingPathComponent("Microsoft Edge", isDirectory: true),
            labelPrefix: "Edge",
            service: "Microsoft Edge Safe Storage",
            account: "Microsoft Edge"
        ))
        profiles.append(contentsOf: discoverChromiumProfiles(
            root: appSupport.appendingPathComponent("Arc/User Data", isDirectory: true),
            labelPrefix: "Arc",
            service: "Chrome Safe Storage",
            account: "Chrome"
        ))
        let opencodeCookies = appSupport.appendingPathComponent("ai.opencode.desktop/Cookies")
        if FileManager.default.fileExists(atPath: opencodeCookies.path) {
            profiles.append(ChromiumProfile(
                label: "OpenCode",
                cookiesURL: opencodeCookies,
                historyURL: nil,
                safeStorageService: "Chrome Safe Storage",
                safeStorageAccount: "Chrome"
            ))
        }
        return profiles
    }

    private static func discoverChromiumProfiles(
        root: URL,
        labelPrefix: String,
        service: String,
        account: String
    ) -> [ChromiumProfile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var profileDirs = ["Default"]
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("Profile ") {
                profileDirs.append(entry.lastPathComponent)
            }
        }
        return profileDirs.compactMap { dir in
            let base = root.appendingPathComponent(dir, isDirectory: true)
            let cookies = base.appendingPathComponent("Cookies")
            guard fm.fileExists(atPath: cookies.path) else { return nil }
            let history = base.appendingPathComponent("History")
            return ChromiumProfile(
                label: "\(labelPrefix) (\(dir))",
                cookiesURL: cookies,
                historyURL: fm.fileExists(atPath: history.path) ? history : nil,
                safeStorageService: service,
                safeStorageAccount: account
            )
        }
    }

    private static func readWorkspaceIdFromAnyProfile() -> String? {
        for profile in chromiumProfiles() {
            guard let historyURL = profile.historyURL else { continue }
            if let workspace = readWorkspaceId(historyURL: historyURL) { return workspace }
        }
        return nil
    }

    // MARK: - Keychain

    private static func readSafeStoragePassword(
        service: String,
        account: String,
        allowsUserInteraction: Bool
    ) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowsUserInteraction {
            applyPassiveKeychainAccess(to: &query)
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }
        return password
    }

    // MARK: - SQLite reads (copy-on-read — browsers lock live DBs)

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func readEncryptedCookie(cookiesURL: URL, host: String, name: String) -> Data? {
        guard let dbURL = copyToTemporaryFile(cookiesURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: dbURL) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT encrypted_value FROM cookies WHERE host_key = ? AND name = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, host, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, name, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: blob, count: count)
    }

    private static func readWorkspaceId(historyURL: URL) -> String? {
        guard let dbURL = copyToTemporaryFile(historyURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: dbURL) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT url FROM urls WHERE url LIKE '%opencode.ai/workspace/%' ORDER BY last_visit_time DESC LIMIT 20"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: cString)
            if let workspace = extractWorkspaceId(from: url) { return workspace }
        }
        return nil
    }

    private static func copyToTemporaryFile(_ source: URL) -> URL? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-browser-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - Chromium cookie decryption (AES-128-CBC + PBKDF2-SHA1)

    private static func decryptChromiumCookie(encrypted: Data, password: String) -> Data? {
        let payload: Data
        if encrypted.count >= 3, encrypted.prefix(3) == Data("v10".utf8) {
            payload = encrypted.dropFirst(3)
        } else {
            payload = encrypted
        }
        guard !payload.isEmpty else { return nil }
        let key = deriveChromeKey(password: password)
        let iv = Data(repeating: 0x20, count: 16)
        guard let decrypted = aes128CBCDecrypt(payload: payload, key: key, iv: iv) else { return nil }
        if let text = String(data: decrypted, encoding: .utf8), !text.isEmpty {
            return Data(text.utf8)
        }
        if decrypted.count > 32 {
            return decrypted.dropFirst(32)
        }
        return decrypted
    }

    private static func deriveChromeKey(password: String) -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: kCCKeySizeAES128)
        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(1), // kCCPRNGSHA1
                        1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        kCCKeySizeAES128
                    )
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        return derived
    }

    private static func applyPassiveKeychainAccess(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query["u_AuthUI"] = "u_AuthUIF"
    }

    private static func aes128CBCDecrypt(payload: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var outLength = payload.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0
        let status = payload.withUnsafeBytes { payloadBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    out.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress, payload.count,
                            outBytes.baseAddress, outLength,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}

#endif
