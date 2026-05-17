import Foundation
import ClawdmeterShared

/// `TokenProvider` impl for Linux — talks to the freedesktop Secret Service
/// API (GNOME Keyring) via libsecret-1. Falls back to a `~/.config/clawdmeter/.token`
/// file at chmod 0600 when no Secret Service daemon is running (headless
/// server installs, fresh distro images before login).
///
/// Schema attributes (must match Mac's KeychainTokenProvider service shape
/// so the daemon's wire is identical):
///     service = "clawdmeter"
///     account = "claude-oauth" | "codex-oauth"
///
/// Phase 3 build-out: actual libsecret C calls (`secret_password_lookup_sync`,
/// `secret_password_store_sync`) live under `#if os(Linux)` + `import CLibSecret`.
/// On macOS dev builds this whole impl is stubbed.
public final class LinuxSecretServiceTokenProvider: TokenProvider, @unchecked Sendable {
    public enum Account: String, Sendable {
        case claudeOAuth = "claude-oauth"
        case codexOAuth = "codex-oauth"
    }

    public let account: Account

    private let lock = NSLock()
    private var cached: String?

    public init(account: Account) {
        self.account = account
    }

    public var currentAccessToken: String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let stored = loadFromSecretService() {
            cached = stored
            return stored
        }
        if let stored = loadFromFallbackFile() {
            cached = stored
            return stored
        }
        return nil
    }

    public var hasToken: Bool {
        currentAccessToken != nil
    }

    public func refreshIfNeeded() async throws -> Bool {
        // Swift 6: NSLock isn't usable across await boundaries. The refresh
        // path is sync (libsecret + file IO) so we just compute outside the
        // async boundary and use lock.withLock for the swap.
        let previous = withLock { cached }
        let fresh = loadFromSecretService() ?? loadFromFallbackFile()
        withLock { cached = fresh }
        return fresh != previous
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Secret Service (libsecret)

    private func loadFromSecretService() -> String? {
        #if os(Linux)
        // TODO(Phase 3 build-out): wire CLibSecret. Approximate flow:
        //   var error: UnsafeMutablePointer<GError>? = nil
        //   let attributes: [String: String] = [
        //       "service": "clawdmeter",
        //       "account": account.rawValue
        //   ]
        //   let attrPtrs = ... // GHashTable from Swift dict
        //   let cPtr = secret_password_lookup_sync(
        //       SECRET_SCHEMA_NONE, nil, &error,
        //       "service", "clawdmeter",
        //       "account", account.rawValue,
        //       nil
        //   )
        //   defer { if cPtr != nil { secret_password_free(cPtr) } }
        //   if let cPtr { return String(cString: cPtr) }
        //   if let error { detectAndFreeError(error) }
        //   return nil
        return nil
        #else
        return nil
        #endif
    }

    private func storeToSecretService(_ token: String) -> Bool {
        #if os(Linux)
        // TODO(Phase 3 build-out): mirror loadFromSecretService with secret_password_store_sync.
        return false
        #else
        return false
        #endif
    }

    // MARK: - File fallback (~/.config/clawdmeter/.token chmod 0600)

    private func loadFromFallbackFile() -> String? {
        let url = LinuxConfigPaths.oauthTokenFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict[account.rawValue]
    }

    /// Write the file fallback with 0600 permissions. Returns false on error.
    @discardableResult
    private func writeFallbackFile(_ token: String) -> Bool {
        do {
            try LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.configHome)
            let url = LinuxConfigPaths.oauthTokenFile
            var dict: [String: String] = [:]
            if let existing = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: String].self, from: existing) {
                dict = decoded
            }
            dict[account.rawValue] = token
            let data = try JSONEncoder().encode(dict)
            // Write umask-tight then chmod for belt-and-suspenders.
            let prevMask = umask(0o077)
            defer { _ = umask(prevMask) }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }
}
