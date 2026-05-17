import Foundation
import ClawdmeterShared

/// `BearerTokenStore` impl for Linux — libsecret-backed pairing token.
/// Same attribute scheme + same generation rules as Mac's `PairingTokenStore`
/// so the wire is byte-identical; only the storage backend differs.
///
/// Schema attributes:
///     service = "clawdmeter-pairing"
///     account = "daemon-bearer-token"
///
/// Phase 3 build-out: actual libsecret C calls under `#if os(Linux)`.
public final class LinuxPairingTokenStore: BearerTokenStore, @unchecked Sendable {
    public static let shared = LinuxPairingTokenStore()

    private let lock = NSLock()
    private var cached: String?

    public init() {}

    public func currentToken() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let stored = loadFromSecretService() ?? loadFromFallbackFile() {
            cached = stored
            return stored
        }
        let fresh = BearerTokenGenerator.generate()
        _ = storeToSecretService(fresh)
        writeFallbackFile(fresh)
        cached = fresh
        return fresh
    }

    @discardableResult
    public func regenerate() -> String {
        lock.lock(); defer { lock.unlock() }
        let fresh = BearerTokenGenerator.generate()
        _ = storeToSecretService(fresh)
        writeFallbackFile(fresh)
        cached = fresh
        return fresh
    }

    public func revoke() {
        lock.lock(); defer { lock.unlock() }
        _ = deleteFromSecretService()
        try? FileManager.default.removeItem(at: LinuxConfigPaths.bearerTokenFile)
        cached = nil
    }

    // MARK: - libsecret

    private func loadFromSecretService() -> String? {
        #if os(Linux)
        // TODO(Phase 3): secret_password_lookup_sync with attrs
        // (service="clawdmeter-pairing", account="daemon-bearer-token").
        return nil
        #else
        return nil
        #endif
    }

    @discardableResult
    private func storeToSecretService(_ token: String) -> Bool {
        #if os(Linux)
        // TODO(Phase 3): secret_password_store_sync.
        return false
        #else
        return false
        #endif
    }

    @discardableResult
    private func deleteFromSecretService() -> Bool {
        #if os(Linux)
        // TODO(Phase 3): secret_password_clear_sync.
        return false
        #else
        return false
        #endif
    }

    // MARK: - File fallback

    private func loadFromFallbackFile() -> String? {
        try? String(contentsOf: LinuxConfigPaths.bearerTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    @discardableResult
    private func writeFallbackFile(_ token: String) -> Bool {
        do {
            try LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.configHome)
            let url = LinuxConfigPaths.bearerTokenFile
            let prevMask = umask(0o077)
            defer { _ = umask(prevMask) }
            try token.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
